import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import VideoToolbox

/// Streaming, **O(1)-memory** time-lapse encoder — the fix for the OOM crash.
///
/// Each captured screenshot is drawn into ONE pooled, reused `CVPixelBuffer`, appended to
/// the hardware (VideoToolbox) encoder, and released immediately. Exactly one frame is live
/// at any instant, so resident memory is independent of recording length: 1 hour and 48 hours
/// have identical RSS. Presentation time is a pure output-domain index
/// (`frameIndex / outputFPS`), which decouples wall-clock capture spacing from video speed.
///
/// Thread-safety: all writer interaction happens on a private serial queue. `@unchecked
/// Sendable` is justified because the queue is the single synchronization point.
final class TimelapseEncoder: @unchecked Sendable {

    let outputURL: URL
    let width: Int
    let height: Int
    private let outputFPS: Int32

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    // .utility QoS keeps encode prep on efficiency cores — frames arrive seconds apart,
    // so latency is irrelevant but the energy difference over 12h is not.
    private let queue = DispatchQueue(label: "com.recvient.RecordTimeLapse.encode", qos: .utility)

    private var frameIndex: Int64 = 0
    private var failed = false
    // Set on the encode queue before markAsFinished(). writer.status stays .writing until
    // finishWriting completes, so status alone can't reject a late append — appending after
    // markAsFinished raises an NSException. This flag closes that crash window.
    private var finishing = false

    init(outputURL: URL, width rawW: Int, height rawH: Int,
         codec: VideoCodec, outputFPS: Int32) throws {
        // Encoders require even dimensions.
        self.width  = max(2, rawW - (rawW % 2))
        self.height = max(2, rawH - (rawH % 2))
        self.outputFPS = max(1, outputFPS)
        self.outputURL = outputURL

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // .mov supports movie fragments → crash-resilient partial files.
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // CRASH SAFETY: flush a movie fragment every 10s. MUST be set before startWriting().
        // If the process dies mid-write, the .mov stays playable up to the last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)

        let codecType: AVVideoCodecType = (codec == .hevc) ? .hevc : .h264
        let bitrate = TimelapseEncoder.suggestedBitrate(width: self.width, height: self.height, fps: Int(self.outputFPS), codec: codec)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            // Static screen content barely changes between events → long GOP shrinks the file.
            AVVideoMaxKeyFrameIntervalKey: Int(self.outputFPS) * 10,
            AVVideoExpectedSourceFrameRateKey: Int(self.outputFPS),
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoCompressionPropertiesKey: compression
        ]

        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Live source (ScreenCaptureKit): maps to kVTCompressionPropertyKey_RealTime so the
        // hardware encoder runs in its streaming configuration (frames seconds apart, no
        // batching latency). The writer never drops frames either way.
        input.expectsMediaDataInRealTime = true

        // Pool attributes serve only the CGImage fallback/test path. The live path appends
        // ScreenCaptureKit's own IOSurface-backed buffers (420v) zero-copy — attributes do
        // not constrain appended buffers, and the pool allocates lazily (i.e. never, in
        // normal recording).
        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: sourceAttrs)

        guard writer.canAdd(input) else {
            throw EncoderError.cannotAddInput
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? EncoderError.startFailed
        }
        // pixelBufferPool is nil until after this call.
        writer.startSession(atSourceTime: .zero)
        Log.encode.info("Encoder started: \(self.width)x\(self.height) \(codec.rawValue) @\(self.outputFPS)fps → \(outputURL.lastPathComponent)")
    }

    /// ZERO-COPY hot path: append a ScreenCaptureKit IOSurface-backed CVPixelBuffer directly.
    /// No draw, no CGImage, no pool — the writer retains the buffer briefly (HW encode is
    /// ~15 ms) and releases it back to SCK's fixed surface pool. O(1) memory.
    @discardableResult
    func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        queue.sync {
            guard waitUntilWritableLocked() else { return false }
            return appendLocked(pixelBuffer)
        }
    }

    /// Fallback/test path: draw a CGImage into a pooled buffer (one buffer live at a time).
    @discardableResult
    func appendFrame(_ cgImage: CGImage) -> Bool {
        queue.sync {
            guard waitUntilWritableLocked() else { return false }
            return autoreleasepool { () -> Bool in
                guard let pool = adaptor.pixelBufferPool else { return false }
                var pb: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
                      let pixelBuffer = pb else { return false }
                PixelBufferRenderer.draw(cgImage, into: pixelBuffer)
                return appendLocked(pixelBuffer)
                // pixelBuffer released here → returns to the pool. RSS stays flat.
            }
        }
    }

    /// Must run on `queue`. Backpressure safety valve: frames arrive seconds apart and the
    /// HW encoder drains in ms, so this practically never blocks. Re-checks writer.status
    /// each spin so a mid-run encoder failure breaks out immediately.
    private func waitUntilWritableLocked() -> Bool {
        guard !failed, !finishing, writer.status == .writing else { return false }
        // Exponential backoff (1 ms → 50 ms, ~10 s total budget): fast recovery for the normal
        // sub-ms drain, few wakeups if the hardware encoder ever genuinely stalls.
        var waited = 0.0
        var delay = 0.001
        while !input.isReadyForMoreMediaData && writer.status == .writing {
            if waited > 10.0 { Log.encode.error("Encoder stalled (not ready for 10s)"); return false }
            Thread.sleep(forTimeInterval: delay)
            waited += delay
            delay = min(0.05, delay * 2)
        }
        guard writer.status == .writing else { failed = true; return false }
        return true
    }

    /// Must run on `queue`, after `waitUntilWritableLocked()`.
    private func appendLocked(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let pts = CMTimeMake(value: frameIndex, timescale: outputFPS)
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            frameIndex += 1
            return true
        } else {
            failed = true
            Log.encode.error("append failed: \(self.writer.error?.localizedDescription ?? "unknown")")
            return false
        }
    }

    /// Finish writing this segment. Async; the file is only valid after this completes.
    func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard !self.finishing, self.writer.status == .writing else {
                    cont.resume(returning: self.writer.status == .completed ? self.outputURL : nil)
                    return
                }
                self.finishing = true
                self.input.markAsFinished()
                self.writer.finishWriting {
                    let ok = self.writer.status == .completed
                    if !ok { Log.encode.error("finishWriting status=\(self.writer.status.rawValue) err=\(self.writer.error?.localizedDescription ?? "nil")") }
                    cont.resume(returning: ok ? self.outputURL : nil)
                }
            }
        }
    }

    /// Rough on-disk size so far (bytes), for the live estimate.
    var bytesOnDisk: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
    }

    // Resolution-aware bitrate. Quality-stable for screen content; HEVC ~half of H.264.
    private static func suggestedBitrate(width: Int, height: Int, fps: Int, codec: VideoCodec) -> Int {
        let bppPerSec = (codec == .hevc) ? 0.07 : 0.13   // bits per pixel per second
        let raw = Double(width * height * fps) * bppPerSec
        return Int(min(max(raw, 2_000_000), 40_000_000)) // clamp 2–40 Mbps
    }

    enum EncoderError: Error { case cannotAddInput, startFailed }
}

import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Event-driven capture: one long-lived `SCStream` with `minimumFrameInterval` set to the
/// time-lapse cadence. WindowServer pushes a frame only when the screen actually changed AND
/// the interval elapsed — between frames (and for as long as the screen is static) neither
/// this process nor the capture pipeline does any work at all. That idle-frame suppression
/// is ScreenCaptureKit's documented energy mechanism (WWDC22), and it is why a persistent
/// low-rate stream beats repeated one-shot screenshots for battery: a one-shot call must
/// set up the pipeline and composite a frame unconditionally, even for an unchanged screen.
///
/// Frames are delivered as IOSurface-backed CVPixelBuffers (420v) and flow zero-copy into
/// the encoder. One engine instance per capture session: closures are immutable.
///
/// Locking: `stopped` is guarded by its own NSLock — NOT the sample-handler queue — because
/// SCK may invoke delegate callbacks on that queue, and a `queue.sync` from the queue itself
/// would deadlock. `stream` is only touched from the main actor (start/update/stop).
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let onStreamError: @Sendable (Error) -> Void
    private let minGap: Duration
    // .utility: prefers efficiency cores but can promote under contention — never .background
    // (I/O-throttled, can stall SCK's fixed surface pool).
    private let queue = DispatchQueue(label: "com.recvient.RecordTimeLapse.capture", qos: .utility)
    private let clock = ContinuousClock()

    private var stream: SCStream?                        // main-actor confined
    private var lastFrameAt: ContinuousClock.Instant?    // touched only on `queue`

    private let stateLock = NSLock()
    private var stopped = false                          // guarded by stateLock

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    init(interval: Double,
         onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
         onStreamError: @escaping @Sendable (Error) -> Void) {
        // minimumFrameInterval is the authoritative pacing; this loose gate only guards
        // pathological bursts (e.g. if SCK clamps very long intervals) and can never
        // reject a legitimately-paced frame arriving with scheduler jitter.
        self.minGap = .seconds(interval * 0.5)
        self.onFrame = onFrame
        self.onStreamError = onStreamError
    }

    func start(target: CaptureTarget) async throws {
        guard !isStopped else { return }
        let stream = SCStream(filter: target.filter, configuration: target.config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Publish the stream BEFORE the async start so a racing stop() can always reach it.
        self.stream = stream
        try await stream.startCapture()
        // stop() may have run while we awaited (its stopCapture on a not-yet-started stream
        // is a no-op) — shut the now-running stream down instead of leaking a live capture.
        if isStopped {
            try? await stream.stopCapture()
            self.stream = nil
            return
        }
        Log.capture.info("Stream capture started")
    }

    /// Seamlessly retarget after a display reconfiguration — no restart needed; the output
    /// canvas is pinned in the configuration, so buffer dimensions never change.
    func update(filter: SCContentFilter) async throws {
        guard let stream, !isStopped else { return }
        try await stream.updateContentFilter(filter)
        Log.capture.info("Stream content filter updated")
    }

    /// Synchronously stop delivering frames (e.g. the instant the user hits Pause),
    /// before the async stream teardown completes.
    func cancelDelivery() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    func stop() async {
        cancelDelivery()
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    // MARK: - SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, !isStopped, CMSampleBufferIsValid(sampleBuffer) else { return }

        // Only fully-composited frames; .idle/.blank carry no new content (and may have no surface).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = clock.now
        if let last = lastFrameAt, now - last < minGap { return }
        lastFrameAt = now

        onFrame(pixelBuffer)
        // The writer retains the buffer asynchronously (~15 ms HW encode) and releases it
        // back to SCK's pool — well under the minimumFrameInterval × (queueDepth−1) budget.
    }

    // MARK: - SCStreamDelegate (may arrive on any queue, including `queue` — no queue.sync here)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Stream stopped with error: \(error.localizedDescription)")
        if !isStopped { onStreamError(error) }
    }
}

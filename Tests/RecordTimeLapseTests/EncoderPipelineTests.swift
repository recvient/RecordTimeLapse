import XCTest
import AVFoundation
import CoreGraphics
@testable import RecordTimeLapse

/// End-to-end functional test of the core pipeline WITHOUT screen capture or TCC permission:
/// feed synthetic frames through the real SegmentManager → TimelapseEncoder (with rotation) →
/// Stitcher, and verify a valid movie of the expected length and dimensions comes out.
final class EncoderPipelineTests: XCTestCase {

    private func makeFrame(_ i: Int, width: Int, height: Int) -> CGImage {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        let r = CGFloat(i % 255) / 255.0
        ctx.setFillColor(CGColor(red: r, green: 0.25, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testStreamingEncodeWithRotationProducesValidVideo() async throws {
        let w = 320, h = 240, fps = 30, total = 200
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtl-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }

        // framesPerSegment = 30 → 200 frames rotates into ~7 segments, exercising the
        // multi-segment composition+passthrough stitch path (not the single-file fast path).
        let manager = try SegmentManager(width: w, height: h, fps: fps, codec: .h264,
                                         outputFolder: outputFolder, framesPerSegment: 30)
        for i in 0..<total {
            XCTAssertTrue(manager.append(makeFrame(i, width: w, height: h)))
        }
        XCTAssertEqual(manager.totalFrames, total)

        let url = await manager.finishAndStitch()
        let finalURL = try XCTUnwrap(url, "stitched output should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

        // Idempotent: a second call returns the same result, doesn't re-stitch.
        let again = await manager.finishAndStitch()
        XCTAssertEqual(again, finalURL)

        // The video must report the expected duration (frames / fps) and dimensions.
        let asset = AVURLAsset(url: finalURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertEqual(duration, Double(total) / Double(fps), accuracy: 0.34,
                       "12h-style timing: length = frames / outputFPS")

        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), w)
        XCTAssertEqual(Int(size.height), h)

        // Working session dir must be cleaned up after a successful stitch.
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workingDir.path))
    }

    /// The ZERO-COPY hot path: append externally-created CVPixelBuffers (as ScreenCaptureKit
    /// delivers them) directly, no CGImage/draw — must still produce a valid video.
    func testZeroCopyPixelBufferAppend() async throws {
        let w = 320, h = 240, fps = 30, total = 90
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtl-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }

        func makeBuffer(_ i: Int) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(i % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        let manager = try SegmentManager(width: w, height: h, fps: fps, codec: .h264,
                                         outputFolder: outputFolder, framesPerSegment: 40)
        for i in 0..<total {
            XCTAssertTrue(manager.append(makeBuffer(i)))
        }
        XCTAssertEqual(manager.totalFrames, total)

        let url = await manager.finishAndStitch()
        let finalURL = try XCTUnwrap(url)
        let asset = AVURLAsset(url: finalURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertEqual(duration, Double(total) / Double(fps), accuracy: 0.34)
    }

    /// Instant start→stop with zero frames must NOT produce a junk "Saved" movie:
    /// the header-only segment is discarded and the session dir cleaned up.
    func testZeroFrameStopProducesNoOutput() async throws {
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtl-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }

        let manager = try SegmentManager(width: 320, height: 240, fps: 30, codec: .h264,
                                         outputFolder: outputFolder, framesPerSegment: 30)
        let url = await manager.finishAndStitch()
        XCTAssertNil(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workingDir.path))

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: outputFolder.path)) ?? []
        XCTAssertTrue(contents.filter { $0.hasSuffix(".mov") }.isEmpty,
                      "no movie files should be produced for a zero-frame session")
    }
}

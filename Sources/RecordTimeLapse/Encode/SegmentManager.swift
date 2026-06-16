import Foundation
import AVFoundation
import CoreGraphics

/// Session metadata persisted to disk so a crashed run can be recovered on next launch.
struct SessionManifest: Codable {
    let sessionID: String
    let width: Int
    let height: Int
    let fps: Int
    let codecRaw: String
    let startedAt: Date
    var segmentFiles: [String]      // creation order, relative to the working dir
    var finalOutputName: String
}

/// Records into rotating fixed-length segment files and stitches them into one final movie.
///
/// Each segment is finalised to a standalone, valid file the moment it rotates, so a crash on a
/// 12-hour run loses at most the last unfinished segment (and even that is partially playable via
/// `movieFragmentInterval`). The canvas size/codec/fps are fixed for the whole session, so the
/// final stitch is a fast pass-through concatenation — no re-encode.
///
/// Thread-safety: every mutable field is guarded by `lock`. `append()` is called from the capture
/// task (off-main); `bytesOnDisk`/`totalFrames`/`fatalMessage`/`warningMessage` are read from the
/// main thread. The lock is never held across the blocking encoder append or across an `await`.
final class SegmentManager: @unchecked Sendable {

    let width: Int
    let height: Int
    let fps: Int
    let codec: VideoCodec
    let outputFolder: URL
    let workingDir: URL
    private let framesPerSegment: Int

    private let lock = NSLock()
    // --- all fields below are guarded by `lock` ---
    private var manifest: SessionManifest
    private var current: TimelapseEncoder?
    private var pendingFinishes: [Task<URL?, Never>] = []
    private var framesInSegment = 0
    private var segmentIndex = 0
    private var _totalFrames = 0
    private var finalizedBytes: Int64 = 0      // size of rotated-away segments (cached → O(1) stat)
    private var finished = false
    private var finalResult: URL?
    private var _fatalMessage: String?         // encoder dead → coordinator should stop & save
    private var _warningMessage: String?       // degraded but still recording (e.g. rotation failed)

    init(width: Int, height: Int, fps: Int, codec: VideoCodec,
         outputFolder: URL, framesPerSegment: Int) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.outputFolder = outputFolder
        self.framesPerSegment = framesPerSegment

        let now = Date()
        let stamp = SegmentManager.fileStamp(now)
        let sessionID = "session-\(stamp)-\(ProcessInfo.processInfo.processIdentifier)"
        self.workingDir = SegmentManager.sessionsRoot().appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        self.manifest = SessionManifest(
            sessionID: sessionID, width: width, height: height, fps: fps,
            codecRaw: codec.rawValue, startedAt: now,
            segmentFiles: [], finalOutputName: "TimeLapse \(stamp).mov")

        // Liveness marker: recovery uses this PID to tell an active session from a crashed one.
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        try? pid.data(using: .utf8)?.write(to: workingDir.appendingPathComponent("session.pid"))

        try startNewSegmentLocked()      // first segment (lock not yet contended)
    }

    /// ZERO-COPY hot path: append a ScreenCaptureKit pixel buffer; rotates when the segment
    /// is full. Returns false if the encoder rejected the frame (e.g. writer failed).
    @discardableResult
    func append(_ pixelBuffer: CVPixelBuffer) -> Bool {
        appendUsing { $0.appendPixelBuffer(pixelBuffer) }
    }

    /// Fallback/test path: append a CGImage via the encoder's pooled-draw path.
    @discardableResult
    func append(_ cgImage: CGImage) -> Bool {
        appendUsing { $0.appendFrame(cgImage) }
    }

    private func appendUsing(_ appendOp: (TimelapseEncoder) -> Bool) -> Bool {
        // Snapshot the current encoder under the lock, then append OUTSIDE the lock.
        lock.lock()
        guard let enc = current, !finished else { lock.unlock(); return false }
        lock.unlock()

        let ok = appendOp(enc)

        var shouldRotate = false
        lock.lock()
        if ok {
            framesInSegment += 1
            _totalFrames += 1
            shouldRotate = framesInSegment >= framesPerSegment
        } else if !finished && _fatalMessage == nil {
            _fatalMessage = "Encoder error — saving what was recorded."
        }
        lock.unlock()

        if shouldRotate { rotate() }
        return ok
    }

    var totalFrames: Int { lock.withLock { _totalFrames } }
    /// Non-nil when the encoder is dead and the coordinator should stop & finalise.
    var fatalMessage: String? { lock.withLock { _fatalMessage } }
    /// Non-nil for degraded-but-recording conditions worth surfacing.
    var warningMessage: String? { lock.withLock { _warningMessage } }

    /// O(1): cached size of finalised segments + a single stat of the live segment.
    var bytesOnDisk: Int64 {
        lock.lock(); let base = finalizedBytes; let cur = current; lock.unlock()
        return base + (cur?.bytesOnDisk ?? 0)
    }

    /// Finalise everything and stitch into one movie in the output folder. Idempotent.
    func finishAndStitch() async -> URL? {
        // Claim finalisation atomically (no await held across the lock).
        let claim: (alreadyDone: Bool, prior: URL?, old: TimelapseEncoder?, pending: [Task<URL?, Never>], frames: Int) =
            lock.withLock {
                if finished { return (true, finalResult, nil, [], 0) }
                finished = true
                let o = current
                current = nil
                let p = pendingFinishes
                pendingFinishes.removeAll()
                return (false, nil, o, p, _totalFrames)
            }
        if claim.alreadyDone { return claim.prior }

        var finishes = claim.pending
        if let old = claim.old { finishes.append(Task { await old.finish() }) }
        for t in finishes { _ = await t.value }

        // Zero frames captured (instant start/stop, or capture never succeeded): the segment
        // files exist but hold only headers — don't ship an empty movie as "Saved".
        guard claim.frames > 0 else { cleanup(); return nil }

        let segments = orderedExistingSegments()
        guard !segments.isEmpty else { cleanup(); return nil }

        let finalURL = uniqueOutputURL(named: manifest.finalOutputName)
        let result = await Stitcher.concatenate(segments, to: finalURL)

        lock.withLock { finalResult = result }
        if result != nil {
            cleanup()
        } else {
            // Stitch failed: KEEP the segments — they are the only copy. Recovery will retry.
            Log.segment.error("Stitch failed; preserving session for recovery at \(self.workingDir.path)")
        }
        return result
    }

    // MARK: - Rotation (lock held throughout the swap)

    private func rotate() {
        lock.lock()
        defer { lock.unlock() }
        guard let old = current, !finished else { return }
        do {
            finalizedBytes += old.bytesOnDisk
            try startNewSegmentLocked()
            pendingFinishes.append(Task { await old.finish() })
            if pendingFinishes.count > 8 {
                Log.segment.error("pendingFinishes high (\(self.pendingFinishes.count)) — encoder flush is slow")
            }
            Log.segment.info("Rotated to segment \(self.segmentIndex)")
        } catch {
            // Keep recording on the existing segment. Reset the counter so we wait a full
            // segment before retrying instead of failing on every subsequent frame.
            framesInSegment = 0
            _warningMessage = "Couldn’t start a new segment: \(error.localizedDescription)"
            Log.segment.error("Segment rotation failed, continuing current: \(error.localizedDescription)")
        }
    }

    /// Must be called with `lock` held.
    private func startNewSegmentLocked() throws {
        let name = String(format: "segment-%04d.mov", segmentIndex)
        let url = workingDir.appendingPathComponent(name)
        let enc = try TimelapseEncoder(outputURL: url, width: width, height: height,
                                       codec: codec, outputFPS: Int32(fps))
        current = enc
        framesInSegment = 0
        segmentIndex += 1
        manifest.segmentFiles.append(name)
        persistManifestLocked()
    }

    private func orderedExistingSegments() -> [URL] {
        let names = lock.withLock { manifest.segmentFiles }
        return names.compactMap { name in
            let url = workingDir.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return size > 0 ? url : nil
        }
    }

    private func persistManifestLocked() {
        let url = workingDir.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func cleanup() {
        if (try? FileManager.default.removeItem(at: workingDir)) == nil {
            Log.segment.error("Failed to remove working dir \(self.workingDir.lastPathComponent)")
        }
    }

    private func uniqueOutputURL(named name: String) -> URL {
        var candidate = outputFolder.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputFolder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Static helpers

    static func sessionsRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("RecordTimeLapse/sessions", isDirectory: true)
    }

    static func fileStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}

/// Pass-through concatenation of same-format segments into a single movie (no re-encode).
enum Stitcher {

    static func concatenate(_ segments: [URL], to finalURL: URL) async -> URL? {
        try? FileManager.default.removeItem(at: finalURL)

        // Single segment: relocate it directly. moveItem fails across volumes (EXDEV) — fall
        // back to copy+remove so saving to an external/network drive still works.
        if segments.count == 1 {
            let src = segments[0]
            do {
                try FileManager.default.moveItem(at: src, to: finalURL)
                return finalURL
            } catch {
                do {
                    try FileManager.default.copyItem(at: src, to: finalURL)
                    try? FileManager.default.removeItem(at: src)
                    return finalURL
                } catch {
                    Log.segment.error("single-segment relocate failed: \(error.localizedDescription)")
                    return nil
                }
            }
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }

        var cursor = CMTime.zero
        var skipped = 0
        for url in segments {
            let asset = AVURLAsset(url: url)
            do {
                guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { skipped += 1; continue }
                let duration = try await asset.load(.duration)
                guard duration > .zero else { skipped += 1; continue }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcTrack, at: cursor)
                cursor = cursor + duration
            } catch {
                skipped += 1
                Log.segment.error("skip unreadable segment \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if skipped > 0 { Log.segment.error("Stitch skipped \(skipped) unreadable segment(s)") }

        guard cursor > .zero,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        export.outputURL = finalURL
        export.outputFileType = .mov

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status == .completed {
            return finalURL
        } else {
            Log.segment.error("stitch export failed: \(export.error?.localizedDescription ?? "unknown")")
            return nil
        }
    }
}

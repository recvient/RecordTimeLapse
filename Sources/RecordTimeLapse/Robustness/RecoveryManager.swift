import Foundation

/// On launch, looks for session working directories left behind by a previous run that crashed
/// or was force-quit mid-recording, and stitches their finalised segments into recovered movies.
/// Thanks to per-segment finalisation, an interrupted 12-hour run still yields everything up to
/// the last few minutes.
enum RecoveryManager {

    private static let staleAge: TimeInterval = 30 * 24 * 3600   // 30 days

    /// Returns URLs of any recovered movies written to the output folder.
    static func recoverOrphans(outputFolder: URL) async -> [URL] {
        let root = SegmentManager.sessionsRoot()
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { return [] }

        var recovered: [URL] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {

            // Skip a session still owned by a live process (e.g. a second running instance).
            if isOwnedByLiveProcess(dir) { continue }

            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data) else {
                removeIfStaleOrEmpty(dir)
                continue
            }

            let segments: [URL] = manifest.segmentFiles.compactMap { name in
                let url = dir.appendingPathComponent(name)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                return size > 0 ? url : nil
            }

            if segments.isEmpty {
                removeIfStaleOrEmpty(dir)
                continue
            }

            try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let finalURL = uniqueURL(in: outputFolder, named: "Recovered \(manifest.finalOutputName)")
            Log.recovery.info("Recovering \(segments.count) orphaned segment(s) from \(dir.lastPathComponent)")

            if let url = await Stitcher.concatenate(segments, to: finalURL) {
                recovered.append(url)
                remove(dir)
            } else {
                // Don't delete: the segments are the only copy. Drop it only once it's truly stale.
                Log.recovery.error("Recovery stitch failed for \(dir.lastPathComponent); keeping for retry")
                removeIfStaleOrEmpty(dir)
            }
        }
        return recovered
    }

    // MARK: - Helpers

    private static func isOwnedByLiveProcess(_ dir: URL) -> Bool {
        let pidURL = dir.appendingPathComponent("session.pid")
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier else { return false }
        // kill(pid, 0): 0 = alive; EPERM = alive but not ours; ESRCH = no such process.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Remove a directory only if it carries no usable data and is old enough to be safe to drop.
    private static func removeIfStaleOrEmpty(_ dir: URL) {
        let mod = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        if Date().timeIntervalSince(mod) > staleAge {
            remove(dir)
        }
    }

    private static func remove(_ dir: URL) {
        if (try? FileManager.default.removeItem(at: dir)) == nil {
            Log.recovery.error("Failed to remove session dir \(dir.lastPathComponent)")
        }
    }

    private static func uniqueURL(in folder: URL, named name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

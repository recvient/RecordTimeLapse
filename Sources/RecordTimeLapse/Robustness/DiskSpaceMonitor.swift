import Foundation

/// Free-space checks for the output volume. The coordinator polls this periodically and stops
/// cleanly (finalising the current segment) before the disk fills, rather than crashing on a
/// failed write hours in.
enum DiskSpaceMonitor {

    /// Bytes available for "important" usage (purgeable space included) on the volume holding `url`.
    static func availableBytes(forVolumeContaining url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Default low-space threshold: stop recording below 2 GB free.
    static let lowSpaceThreshold: Int64 = 2_000_000_000

    static func isLow(forVolumeContaining url: URL) -> Bool {
        guard let free = availableBytes(forVolumeContaining: url) else { return false }
        return free < lowSpaceThreshold
    }
}

import Foundation
import Observation
import CoreGraphics

/// Output video codec.
enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc   // smallest files, hardware-encoded; default
    case h264   // maximum compatibility (old macOS / Windows)
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC (small files)" : "H.264 (max compatibility)" }
}

/// Capture resolution policy: cap the long edge of the captured frame.
/// 0 == native (no downscale). Lower = less energy, smaller files.
enum ResolutionCap: Int, CaseIterable, Identifiable {
    case native = 0
    case uhd    = 3840
    case wqhd   = 2560
    case fhd    = 1920
    case hd     = 1280
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .native: return "Native (full resolution)"
        case .uhd:    return "Up to 4K (3840)"
        case .wqhd:   return "Up to 2560 (recommended)"
        case .fhd:    return "Up to 1080p (1920)"
        case .hd:     return "Up to 720p (1280)"
        }
    }
}

/// Single shared, observable, persisted settings store.
/// Read by the `RecordingCoordinator`; edited by `PreferencesView`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let interval        = "captureInterval"
        static let fps             = "outputFPS"
        static let codec           = "videoCodec"
        static let resolutionCap   = "resolutionCap"
        static let showsCursor     = "showsCursor"
        static let pauseOnSleep    = "pauseOnSleep"
        static let preventIdleSleep = "preventIdleSleep"
        static let outputFolder    = "outputFolderPath"
        static let targetDisplay   = "targetDisplayID"   // 0 == main display
        static let segmentMinutes  = "segmentMinutes"
        static let launchAtLogin   = "launchAtLogin"
    }

    /// Seconds of real time between captured screenshots.
    var captureInterval: Double { didSet { defaults.set(captureInterval, forKey: Key.interval) } }
    /// Output video frame rate. Video length = framesCaptured / outputFPS.
    var outputFPS: Int { didSet { defaults.set(outputFPS, forKey: Key.fps) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    var resolutionCap: ResolutionCap { didSet { defaults.set(resolutionCap.rawValue, forKey: Key.resolutionCap) } }
    var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: Key.showsCursor) } }
    var pauseOnSleep: Bool { didSet { defaults.set(pauseOnSleep, forKey: Key.pauseOnSleep) } }
    var preventIdleSleep: Bool { didSet { defaults.set(preventIdleSleep, forKey: Key.preventIdleSleep) } }
    var targetDisplayID: CGDirectDisplayID { didSet { defaults.set(Int(targetDisplayID), forKey: Key.targetDisplay) } }
    var segmentMinutes: Int { didSet { defaults.set(segmentMinutes, forKey: Key.segmentMinutes) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }

    /// Where finished time-lapses are written.
    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    private init() {
        // Register defaults, then read.
        defaults.register(defaults: [
            Key.interval: 2.0,
            Key.fps: 30,
            Key.codec: VideoCodec.hevc.rawValue,
            Key.resolutionCap: ResolutionCap.wqhd.rawValue,
            Key.showsCursor: false,
            Key.pauseOnSleep: true,
            Key.preventIdleSleep: false,
            Key.targetDisplay: 0,
            Key.segmentMinutes: 5,
            Key.launchAtLogin: false
        ])

        captureInterval  = defaults.double(forKey: Key.interval)
        outputFPS        = max(1, defaults.integer(forKey: Key.fps))
        codec            = VideoCodec(rawValue: defaults.string(forKey: Key.codec) ?? "hevc") ?? .hevc
        resolutionCap    = ResolutionCap(rawValue: defaults.integer(forKey: Key.resolutionCap)) ?? .wqhd
        showsCursor      = defaults.bool(forKey: Key.showsCursor)
        pauseOnSleep     = defaults.bool(forKey: Key.pauseOnSleep)
        preventIdleSleep = defaults.bool(forKey: Key.preventIdleSleep)
        targetDisplayID  = CGDirectDisplayID(defaults.integer(forKey: Key.targetDisplay))
        segmentMinutes   = max(1, defaults.integer(forKey: Key.segmentMinutes))
        launchAtLogin    = defaults.bool(forKey: Key.launchAtLogin)

        if let saved = defaults.string(forKey: Key.outputFolder) {
            outputFolder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            outputFolder = AppSettings.defaultOutputFolder()
        }
    }

    static func defaultOutputFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("RecordTimeLapse", isDirectory: true)
    }

    /// Number of captured frames after which the encoder rotates to a new segment file.
    /// `segmentMinutes` is WALL-CLOCK time: a checkpoint every N minutes of real recording,
    /// regardless of capture interval or output FPS. Segments bound crash-loss and
    /// finishWriting latency over multi-hour runs. Clamped to ≥10 frames so very long
    /// capture intervals don't degenerate into per-frame segment files.
    var framesPerSegment: Int {
        let frames = Double(segmentMinutes) * 60.0 / max(0.1, captureInterval)
        return max(10, Int(frames.rounded()))
    }
}

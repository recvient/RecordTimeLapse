import Foundation
import Observation

/// Main-thread, view-facing projection of recording state. Pure data — no capture
/// logic. The `RecordingCoordinator` mutates this on the main thread; SwiftUI observes it.
@Observable
@MainActor
final class RecorderModel {
    enum State: Equatable {
        case idle
        case recording
        case paused(reason: String)   // user pause, or auto-pause (sleep/lock)
        case finalizing
    }

    var state: State = .idle

    // Live stats
    var frameCount: Int = 0
    var activeSeconds: TimeInterval = 0      // wall-clock time spent actually capturing
    var estimatedBytes: Int64 = 0

    // Environment
    var permissionGranted: Bool = false
    var diskWarning: String? = nil
    var lastOutputURL: URL? = nil
    var statusMessage: String? = nil

    var isRecording: Bool {
        if case .idle = state { return false }
        return true
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// SF Symbol used as the menu-bar icon.
    var menuBarSymbol: String {
        switch state {
        case .idle:       return "record.circle"
        case .recording:  return "record.circle.fill"
        case .paused:     return "pause.circle.fill"
        case .finalizing: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    /// Short human status line for the menu.
    var statusLine: String {
        switch state {
        case .idle:                   return statusMessage ?? "Idle"
        case .recording:              return "Recording"
        case .paused(let reason):     return reason   // full label, e.g. "Paused — display sleep"
        case .finalizing:             return "Finalizing…"
        }
    }

    /// Predicted finished-video length at the current output FPS.
    func projectedVideoLength(outputFPS: Int) -> TimeInterval {
        guard outputFPS > 0 else { return 0 }
        return TimeInterval(frameCount) / TimeInterval(outputFPS)
    }
}

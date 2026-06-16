import Foundation
import AppKit

/// Emits pause/resume events for system sleep, display sleep, and screen lock so the recorder
/// never bakes black/idle frames into the time-lapse. Because the video timeline is frame-index
/// based, pausing simply stops appending frames — the resumed footage continues seamlessly with
/// no gap and no black stretch. Callbacks are delivered on the main thread.
/// All methods/callbacks run on the main queue (observers registered with `queue: .main`,
/// start/stop called from the main-actor coordinator), so the mutable `isStopped`/token state
/// is effectively main-confined. `@unchecked Sendable` documents that invariant.
final class PowerStateObserver: @unchecked Sendable {

    /// Reason string (e.g. "display sleep"). Called when the recorder should auto-pause.
    var onPause: ((String) -> Void)?
    /// Called when the recorder may auto-resume.
    var onResume: (() -> Void)?

    private var wsTokens: [NSObjectProtocol] = []
    private var dncTokens: [NSObjectProtocol] = []
    private var isStopped = true

    func start() {
        guard isStopped else { return }   // pair start/stop; never double-register
        isStopped = false

        let ws = NSWorkspace.shared.notificationCenter
        observeWS(ws, NSWorkspace.willSleepNotification)        { [weak self] in self?.onPause?("system sleep") }
        observeWS(ws, NSWorkspace.didWakeNotification)          { [weak self] in self?.onResume?() }
        observeWS(ws, NSWorkspace.screensDidSleepNotification)  { [weak self] in self?.onPause?("display sleep") }
        observeWS(ws, NSWorkspace.screensDidWakeNotification)   { [weak self] in self?.onResume?() }

        let dnc = DistributedNotificationCenter.default()
        observeDNC(dnc, Notification.Name("com.apple.screenIsLocked"))   { [weak self] in self?.onPause?("screen locked") }
        observeDNC(dnc, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.onResume?() }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true   // in-flight queued callbacks bail out via the isStopped check
        let ws = NSWorkspace.shared.notificationCenter
        for t in wsTokens { ws.removeObserver(t) }
        let dnc = DistributedNotificationCenter.default()
        for t in dncTokens { dnc.removeObserver(t) }
        wsTokens.removeAll()
        dncTokens.removeAll()
    }

    private func observeWS(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping () -> Void) {
        wsTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isStopped else { return }
            block()
        })
    }

    private func observeDNC(_ center: DistributedNotificationCenter, _ name: Notification.Name, _ block: @escaping () -> Void) {
        dncTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isStopped else { return }
            block()
        })
    }
}

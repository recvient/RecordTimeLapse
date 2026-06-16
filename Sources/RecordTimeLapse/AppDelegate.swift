import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would race on the session working directories.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first {
                other.activate()
                NSApp.terminate(nil)
                return
            }
        }

        // Background/menu-bar app: no Dock icon, no main window (belt-and-suspenders with LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        let outputFolder = AppSettings.shared.outputFolder

        Task { @MainActor in
            // Recover any session left behind by a previous crash / force-quit.
            let recovered = await RecoveryManager.recoverOrphans(outputFolder: outputFolder)
            if let last = recovered.last {
                let model = RecordingCoordinator.shared.model
                model.statusMessage = "Recovered \(recovered.count) interrupted recording(s)"
                model.lastOutputURL = last
            }
            RecordingCoordinator.shared.refreshPermission()
        }
    }

    // Keep running when the (non-existent) last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

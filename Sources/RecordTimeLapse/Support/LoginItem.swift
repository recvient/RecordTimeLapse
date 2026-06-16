import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Requires a code-signed .app to take effect;
/// errors are logged and swallowed so running the bare `swift run` binary doesn't crash.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription)")
        }
    }
}

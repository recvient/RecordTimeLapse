import Foundation
import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission. There is no Info.plist entitlement for the standard
/// ScreenCaptureKit case — the OS prompts on first capture. `CGPreflight…` checks without
/// prompting; `CGRequest…` actively prompts (only the first time; after a decision the user
/// must change it in System Settings).
enum PermissionService {

    /// Non-prompting status check.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompt once if not yet granted. Returns the resulting grant state.
    /// `CGRequestScreenCaptureAccess` is a blocking call that presents a system dialog, so it
    /// runs off the main thread to keep the menu-bar UI responsive.
    @discardableResult
    static func requestIfNeeded() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: CGRequestScreenCaptureAccess())
            }
        }
        Log.capture.info("Screen Recording permission requested → granted=\(granted)")
        return granted
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

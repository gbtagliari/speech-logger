import AppKit
import CoreGraphics

/// The Input Monitoring (TCC) permission the hotkey needs (ADR-0004). Trust
/// `CGPreflightListenEventAccess()`, never the Settings toggle — the toggle lies
/// after a DR-invalidating rebuild, showing ON while preflight is false.
///
/// Preflight is a **launch-time read**: it does not update live within a running
/// process when the user grants mid-session. Detect a fresh grant by relaunching,
/// not by polling. Onboarding deep-links to the pane and relies on relaunch.
enum InputMonitoring {
    /// Whether the process may listen for global key events. Never prompts.
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    /// Request the permission. Prompts once **iff** no prior TCC decision exists;
    /// with any recorded decision it returns immediately without a prompt, so the
    /// caller must fall back to the Settings deep-link rather than re-ask.
    @discardableResult
    static func request() -> Bool { CGRequestListenEventAccess() }

    /// Open System Settings straight to the Input Monitoring pane.
    static func openSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
import ApplicationServices

/// The Accessibility (TCC) permission the dictation paste needs, and needs alone
/// (ADR-0007). Capture is untouched: the hotkey keeps Input Monitoring, and braindump
/// needs neither.
///
/// This grant is what revokes ADR-0004's guarantee that the app is *structurally
/// incapable* of reading typed text. With it the capability exists, and what remains is
/// that the app **chooses not to** — kept by the same two rules, now as policy: match
/// modifier flags only, never key-down (`HotkeyMonitor`), and never install a capturing
/// event tap for capture.
///
/// Read live, unlike Input Monitoring: `AXIsProcessTrusted()` reflects a mid-session
/// grant or revocation in the running process, so the banner clears on focus and the
/// paste-time re-check is a real check rather than a cached launch-time answer. The
/// grant survives a rebuild given the stable signing identity of ADR-0005 (verified in
/// #28), so developing the app does not mean re-authorizing it.
enum Accessibility {
    /// Whether the process may post the synthetic paste. Never prompts.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The banner's grant button: register with TCC, then open the pane.
    ///
    /// Both halves are needed, and this is where Accessibility differs from Input
    /// Monitoring. `AXIsProcessTrusted()` is a passive read that, unlike
    /// `CGPreflightListenEventAccess()`, never adds the app to the Accessibility list —
    /// so a button that only deep-linked would drop the user into a pane with **no row
    /// to toggle**. Asking for the grant is what creates the row (#28 saw exactly this:
    /// "prompted (added to Accessibility list)"). The deep-link then still runs, because
    /// the ask is a no-op once any decision has been recorded and the pane is the only
    /// way back from a denial.
    static func requestGrant() {
        _ = AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary)
        openSettings()
    }

    /// `kAXTrustedCheckOptionPrompt`, spelled out. The imported constant is a global
    /// `var` of shared mutable state, which Swift 6 strict concurrency refuses; its
    /// value is this fixed string and is part of the framework's public contract.
    private static let promptOption = "AXTrustedCheckOptionPrompt"

    /// Open System Settings straight to the Accessibility pane, by the same anchored
    /// legacy form the Input Monitoring and Microphone deep-links use.
    private static func openSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

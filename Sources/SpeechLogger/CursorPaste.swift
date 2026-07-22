import CoreGraphics

/// The paste at the cursor: a synthetic `Cmd+V` posted into whatever has focus
/// (ADR-0007, verified across real targets in #28).
///
/// **The paste is blind.** Reading the focused element is not the mechanism and is not
/// possible — the system-wide accessibility query for it returned no value on 100% of
/// targets tested, terminal to Spotlight — so there is nothing to inspect before
/// posting, nothing to confirm after, and a secure-field guard by accessibility subrole
/// would be dead code (macOS hides secure fields from that API entirely).
///
/// That is also why nothing here is mocked or asserted in a test: success is
/// undetectable by construction, so a test around this would only assert its own fake.
/// What *is* tested is everything that decides whether to call it (`AutoPasteGuard`).
/// The rest is the manual matrix.
///
/// Residual risk, knowingly accepted: the OS drops the synthetic paste into a **native**
/// password field, but a **web or Electron** one is neither protected nor detectable.
enum CursorPaste {
    /// `kVK_ANSI_V`. The keystroke is posted by virtual key code, so it is the physical
    /// V position and does not move with the layout.
    private static let vKeyCode: CGKeyCode = 9

    /// Post `Cmd+V` at the HID tap, as if typed. The text must already be on the
    /// pasteboard — the clipboard write is the payload *and* the recovery net, so it
    /// happens first and is never undone.
    static func post() {
        // `.combinedSessionState` so the event carries the session's real modifier
        // state; a private state would post V with no working Command.
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

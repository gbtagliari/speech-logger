# ADR-0004 — Global hotkey via a flagsChanged monitor over Input Monitoring

Status: accepted
Date: 2026-07-15

## Context

The app is triggered by a global hotkey that must fire while any other app is focused. The PRD wanted
a double-tap that is **not** Control (Control double-tap belongs to macOS dictation) and claimed the
app would need no Accessibility permission. The research ticket set out to make the capture concrete
and to test that permission claim.

## Decision

Capture the hotkey with **`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`**, gated by an
explicit **`CGPreflightListenEventAccess()`** call. This costs **Input Monitoring** only — not
Accessibility.

- The hotkey is **Right-Option double-tap** (keyCode **61**; left Option is 58), 300 ms window, both
  hard-coded, no rebind or settings in the MVP. Right over left because left Option is the pt-BR accent
  modifier while right is inert during typing.
- Match on **`.flagsChanged` only, never `.keyDown`.** Consequence promoted to a product guarantee:
  **the app is structurally incapable of reading typed text.** It should stay that way.
- Mask the raw flag word to **`0x207F`** before testing for the modifier. The obvious "no other
  modifier held" test is otherwise always true (the word carries the general-modifier bit `0x80000`
  and `NX_NONCOALESCEDMASK` `0x100`), so the detector silently never fires.

## Consequences

- **The app cannot swallow the double-tap.** A `listenOnly` tap is permitted with Accessibility
  denied; a `defaultTap` (which could alter the event stream) is refused. Both key presses therefore
  also reach the frontmost app (**passthrough**). Benign — Option alone inserts nothing.
- The PRD's "no Accessibility" claim **holds, but its reason was wrong**: the line macOS draws is not
  "do you synthesize keystrokes", it is "can you alter the event stream".
- `CGEventTap` was measured to deliver byte-identical data (162/162 events) and buys nothing over the
  simpler `NSEvent` monitor, while costing a run-loop source and a disable-recovery path. Not used.
- There is no system API or readable preference for the double-tap window; 300 ms is ours to choose.
- Carbon `RegisterEventHotKey` **cannot** bind a modifier-only hotkey (returns `noErr`, never fires),
  but is the zero-permission answer **if** the hotkey ever becomes an ordinary combo — a live lever if
  the Input Monitoring requirement ever needs to disappear.
- Grant durability across rebuilds is a separate hard constraint (ADR-0005). Full contract:
  [`docs/research/global-hotkey-capture-macos.md`](../research/global-hotkey-capture-macos.md).
</content>

import Foundation

/// Detects a **right-Option double-tap** from a stream of `flagsChanged` events
/// (ADR-0004). Pure logic over `(keyCode, rawFlags, now)` so it is unit-testable
/// without a live event monitor — which matters, because this is the seam where
/// "the detector silently never fires" lives.
///
/// The load-bearing move is masking the raw flag word to the **device bits**
/// (`0x207F`) before any modifier test. The raw word also carries the *general*
/// modifier bit (`0x80000` for Option) and `NX_NONCOALSESCEDMASK` (`0x100`), so
/// the natural "is any other modifier held?" test on the raw word is always true
/// and the gesture is never recognized. See `global-hotkey-capture-macos.md`.
///
/// A press and a release are **both** `flagsChanged`; direction comes from the
/// device bit, not the event type. The detector fires on the *rising edge* of the
/// second press within the window.
public struct HotkeyDetector: Sendable {
    /// `kVK_RightOption`. Left Option (58) is the pt-BR accent modifier and is
    /// deliberately not the trigger.
    private static let rightOptionKeyCode: Int64 = 61
    /// `NX_DEVICERALTKEYMASK` — right-Option's device bit.
    private static let rightOptionBit: UInt64 = 0x40
    /// Union of the eight device-dependent modifier bits. Mask to this *first*.
    private static let deviceMask: UInt64 = 0x207F

    /// The double-tap window. No system API or preference exposes one; 300 ms was
    /// tuned on-device (ADR-0004). Above ~500 ms it catches accidental drum-rolls;
    /// below ~200 ms it is hard to hit deliberately.
    private let window: TimeInterval

    /// Timestamp of the last accepted first tap. Seeded far in the past so the
    /// very first tap can never satisfy the window on its own.
    private var lastTapAt: TimeInterval = -.greatestFiniteMagnitude
    /// Whether right-Option was down on the previous relevant event, so a held key
    /// (repeat / stuck flag) collapses to a single tap instead of spamming.
    private var wasDown = false

    public init(window: TimeInterval = 0.30) {
        self.window = window
    }

    /// Feed one `flagsChanged` event. Returns `true` exactly on the second qualifying
    /// press within the window (the "toggle recording" moment).
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code of the modifier that changed.
    ///   - flags: the raw modifier word (`NSEvent.modifierFlags.rawValue`), device
    ///     bits included.
    ///   - now: a **monotonic** timestamp (event `.timestamp` or `CACurrentMediaTime()`),
    ///     never wall-clock — `Date()` jumps on NTP sync.
    public mutating func handle(keyCode: Int64, flags: UInt64, now: TimeInterval) -> Bool {
        // Some other modifier moved; not our key.
        guard keyCode == Self.rightOptionKeyCode else { return false }

        let device = flags & Self.deviceMask  // the trap: mask before testing anything
        let isDown = device & Self.rightOptionBit != 0
        defer { wasDown = isDown }

        // Rising edge only: ignore the release and any held-key repeats.
        guard isDown, !wasDown else { return false }

        // Right-Option as part of a combo (⌥⇧, ⌥⌘…) is not the gesture; cancel.
        if device & ~Self.rightOptionBit != 0 {
            lastTapAt = -.greatestFiniteMagnitude
            return false
        }

        if now - lastTapAt <= window {
            lastTapAt = -.greatestFiniteMagnitude  // consume, so a third tap re-arms
            return true
        }
        lastTapAt = now
        return false
    }
}

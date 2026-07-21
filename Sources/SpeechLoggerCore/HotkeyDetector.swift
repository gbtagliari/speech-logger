import Foundation

/// What the hotkey just asked for. One key, two modes, and the gesture is the only
/// thing that tells them apart (CONTEXT.md, "the hotkey grammar").
public enum HotkeyGesture: Sendable, Equatable {
    /// Tap 2 landed from idle: open the mic **now**. Which mode this will turn out to
    /// be is not known yet and deliberately does not gate the audio — what waits for
    /// the threshold is the label, not the recording.
    case start
    /// The recording is over, labeled by the gesture that ended it: a quick release
    /// made it a braindump toggle, a hold past `T` made it a dictation.
    case stop(ItemMode)
}

/// Detects the **right-Option hotkey grammar** from a stream of `flagsChanged`
/// events (ADR-0004): a double-tap starts a recording, and how long tap 2 is held
/// decides whether it is a braindump toggle or a push-to-talk dictation (#42). Pure
/// logic over `(keyCode, rawFlags, now, isRecording)` so it is unit-testable without
/// a live event monitor — which matters, because this is the seam where "the
/// detector silently never fires" lives.
///
/// The load-bearing move is masking the raw flag word to the **device bits**
/// (`0x207F`) before any modifier test. The raw word also carries the *general*
/// modifier bit (`0x80000` for Option) and `NX_NONCOALSESCEDMASK` (`0x100`), so
/// the natural "is any other modifier held?" test on the raw word is always true
/// and the gesture is never recognized. See `global-hotkey-capture-macos.md`.
///
/// A press and a release are **both** `flagsChanged`; direction comes from the
/// device bit, not the event type. That is also why the hold costs nothing: the
/// whole grammar, hold included, rides the one permission the app already has.
///
/// **No timer.** "Still down at `T`" is decided on the release event, by how long
/// tap 2 was held — the mode is not observable before then anyway, since a dictation
/// ends on that very release and a braindump keeps recording either way. A timer
/// would fire into an app that had nothing to do with the news.
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
    /// `T`, the mode threshold: tap 2 released before it is a braindump toggle, still
    /// down at it is a dictation. Injectable exactly like `window`, for on-device
    /// tuning — 250 ms sits above a deliberate double-tap's second release and below
    /// the shortest hold anyone means as a hold.
    private let holdThreshold: TimeInterval

    /// Timestamp of the last accepted first tap. Seeded far in the past so the
    /// very first tap can never satisfy the window on its own.
    private var lastTapAt: TimeInterval = -.greatestFiniteMagnitude
    /// Whether right-Option was down on the previous relevant event, so a held key
    /// (repeat / stuck flag) collapses to a single tap instead of spamming.
    private var wasDown = false
    /// When tap 2 went down, while its label is still open — the grammar's whole
    /// memory of the live recording, and *not* "is the mic open", which is the
    /// coordinator's and is passed in. Non-nil only between tap 2's press and its
    /// release: past `T` that release ends a dictation, under `T` it settles as a
    /// braindump toggle and the recording carries on with nothing owed.
    private var labelPendingSince: TimeInterval?

    public init(window: TimeInterval = 0.30, holdThreshold: TimeInterval = 0.25) {
        self.window = window
        self.holdThreshold = holdThreshold
    }

    /// Feed one `flagsChanged` event and get back what it asked for, if anything.
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code of the modifier that changed.
    ///   - flags: the raw modifier word (`NSEvent.modifierFlags.rawValue`), device
    ///     bits included.
    ///   - now: a **monotonic** timestamp (event `.timestamp` or `CACurrentMediaTime()`),
    ///     never wall-clock — `Date()` jumps on NTP sync.
    ///   - isRecording: whether the mic is actually live, straight from the recording
    ///     coordinator. It is the truth, not this detector's belief: a start the
    ///     coordinator refused (an unusable microphone, #45) or a stop that came from
    ///     somewhere else (the panel, a quit) must leave the grammar back at idle
    ///     rather than owing a stop nobody can deliver.
    public mutating func handle(
        keyCode: Int64, flags: UInt64, now: TimeInterval, isRecording: Bool
    ) -> HotkeyGesture? {
        // Some other modifier moved; not our key.
        guard keyCode == Self.rightOptionKeyCode else { return nil }

        let device = flags & Self.deviceMask  // the trap: mask before testing anything
        let isDown = device & Self.rightOptionBit != 0
        defer { wasDown = isDown }

        if !isRecording { labelPendingSince = nil }

        // The release: the only event that can label a recording, and a dictation's stop.
        guard isDown else { return releasing(at: now) }

        // Rising edge only: ignore any held-key repeats.
        guard !wasDown else { return nil }

        // Right-Option as part of a combo (⌥⇧, ⌥⌘…) is not the gesture; cancel.
        if device & ~Self.rightOptionBit != 0 {
            lastTapAt = -.greatestFiniteMagnitude
            return nil
        }

        guard now - lastTapAt <= window else {
            lastTapAt = now  // a first tap, arming the window
            return nil
        }
        lastTapAt = -.greatestFiniteMagnitude  // consume, so a third tap re-arms

        // **Recording wins the key**: from a live recording every gesture only stops
        // it, so the grammar (and the hold) applies from idle alone. Stopping on the
        // press is what makes the hold irrelevant here — there is nothing left to label.
        //
        // Always a braindump: a dictation is held down for its whole life, so it can
        // only ever end on its own release, and no second press can reach this line
        // while one is in flight.
        guard !isRecording else {
            labelPendingSince = nil
            return .stop(.braindump)
        }

        labelPendingSince = now
        return .start
    }

    /// Right-Option came up. It means something only while tap 2's label is still
    /// open: past `T` this is a dictation ending, under `T` it was a toggle and the
    /// recording keeps running with nothing to report.
    private mutating func releasing(at now: TimeInterval) -> HotkeyGesture? {
        guard let pressedAt = labelPendingSince else { return nil }
        labelPendingSince = nil
        guard now - pressedAt >= holdThreshold else { return nil }
        return .stop(.dictation)
    }
}

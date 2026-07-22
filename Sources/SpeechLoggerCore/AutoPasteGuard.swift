import Foundation

/// What a finished dictation gets: the paste, or the sound that says it did not land.
///
/// There is no third outcome and no success chime — the text appearing in the field is
/// the confirmation. The sound's two meanings (the dictation failed, or the text is
/// ready but did not land) are the only signals the mode has.
public enum DictationDelivery: Sendable, Equatable {
    /// Post the paste keystroke at the cursor. Silent.
    case paste
    /// The text is ready but did not land — queued behind a braindump, the guard
    /// disarmed, the grant withheld, the paste swallowed. Sound, no paste. The
    /// clipboard still holds the transcript, which is the recovery.
    case sound
}

/// The auto-paste guard (ADR-0007, #43): whether a finished dictation may still be
/// pasted where the cursor was when the key came up.
///
/// **A boolean over app-activation events, not a deadline.** It arms on key release,
/// disarms on the first app activation, and the paste fires only if still armed. A
/// time-to-live was rejected as a bad proxy in both directions: it fires wrongly if you
/// switch apps at 1.5 s, and wrongly withholds if you sit still for 30 s.
///
/// ```
/// idle       --(key release)-->        armed
/// armed      --(any app activated)-->  disarmed
/// armed      --(transcript ready)-->   paste
/// disarmed   --(transcript ready)-->   no paste, sound
/// ```
///
/// Literally a boolean, and that is load-bearing: **reading it does not clear it.** The
/// state machine above is drawn for one dictation, but two can be in flight (the mode
/// is built for two-second commands, and a transcript takes ~2.5 s), and a guard that
/// disarmed itself on the first transcript would silently withhold the paste of every
/// dictation after it. The question the boolean answers is about the world, not about
/// an item: *has focus moved since you last let go of the key?* A transcript arriving
/// is not focus moving, so it changes nothing — only an activation and the next release
/// do. This is why there is no reset and no per-item bookkeeping: an arming left behind
/// by a hold that never produced a transcript (one below the duration floor, or silent)
/// is overwritten by the next release rather than desynchronising anything.
///
/// A pure value: the workspace observation that feeds `appDidActivate()` is a thin
/// adapter in the app target, deliberately **outside** this seam, so the whole decision
/// is testable with no running window server. The one thing it is not is the posting of
/// the keystroke — that is undetectable by construction, so there is nothing here to
/// assert about it.
///
/// Verified in the #39 prototype: nothing on the happy path self-disarms — not the
/// synthetic keystroke, not the sound, not the menubar icon mutation, not a five-second
/// hold. Only a genuine activation does.
///
/// - Accepted consequence: the app activating itself disarms too, so clicking the
///   menubar between release and paste kills the auto-paste. That is correct.
/// - Accepted hole: same app, different field. The guard sees app focus, never the caret.
public struct AutoPasteGuard: Sendable, Equatable {
    /// Whether focus has stayed put since the last key release. False before the first
    /// dictation of the session: nothing has been released, so nothing is owed a paste.
    public private(set) var isArmed = false

    public init() {}

    /// The key came up, ending a dictation. From here on, any app activation means the
    /// user is no longer looking at the field they dictated into.
    ///
    /// Fired on the release itself, not on the recording being accepted: a hold that is
    /// discarded as too short or silent simply never produces a transcript, and an
    /// armed guard with nothing coming costs nothing.
    public mutating func arm() {
        isArmed = true
    }

    /// Some app was activated. Which one is not asked and deliberately not knowable
    /// from here: an activation is an activation, including this app's own.
    public mutating func appDidActivate() {
        isArmed = false
    }

    /// The transcript is ready: paste it, or sound because it did not land.
    ///
    /// Non-mutating, which is the whole point of the boolean — see the type's note on
    /// why reading does not clear it.
    ///
    /// - Parameter isTrusted: `AXIsProcessTrusted()`, read **now** rather than at
    ///   launch, because the grant can be revoked in between. Injected because it is an
    ///   ApplicationServices call and this target is pure. Withheld, nothing is posted
    ///   and the item and the clipboard stand — the mode degrades, it does not die.
    public func transcriptReady(isTrusted: Bool) -> DictationDelivery {
        isArmed && isTrusted ? .paste : .sound
    }
}

import Foundation

/// What a discarded recording measured, for the one line that says so (#67).
///
/// A discard leaves no item on purpose (#46): an accidental double-tap you already
/// noticed is not worth a `failed` entry in the log. The cost of that decision is that
/// the *other* recording it deletes — a real braindump the speech test read wrong —
/// leaves nothing to look at either. A five-second braindump vanished with no item, no
/// failure and no log line, and the only reason the threshold was ever found to be the
/// cause is that an energy dump happened to be switched on.
///
/// So the verdict carries its measurements out to the caller, which logs them. Every
/// field is something the recording measured, so the line they make is enough to tell
/// "you said nothing" from "the floor was wrong" without re-running a recording that no
/// longer exists.
public struct DiscardedRecording: Sendable, Equatable {
    /// Which discard it was: too short, or no speech in it.
    public let decision: GuardDecision
    /// The mode the gesture earned, since the duration floor is per mode.
    public let mode: ItemMode
    /// The recording's measured length, in seconds.
    public let duration: TimeInterval
    /// How many energy windows the capture produced.
    public let windows: Int
    /// The loudest window in the recording, in RMS amplitude (0…1).
    public let peak: Float
    /// The speech test's two numbers, or **nil when there were no windows to measure**.
    /// A capture that closed no window has no floor and no fraction, and printing the
    /// bare cap next to a 0% that was never counted would put a threshold in the log
    /// that nothing was ever compared against.
    public let speech: RecordingGuard.SpeechMeasurement?

    public init(
        decision: GuardDecision, mode: ItemMode, duration: TimeInterval, windows: Int,
        peak: Float, speech: RecordingGuard.SpeechMeasurement?
    ) {
        self.decision = decision
        self.mode = mode
        self.duration = duration
        self.windows = windows
        self.peak = peak
        self.speech = speech
    }
}

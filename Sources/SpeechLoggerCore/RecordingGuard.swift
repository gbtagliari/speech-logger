import Foundation

/// The dual guard's verdict on a finished recording.
public enum GuardDecision: Sendable, Equatable {
    /// Long enough and loud enough: encode it and queue it.
    case accept
    /// Below the minimum duration: an accidental tap. Discard silently: it never
    /// becomes a log item, so a fat-fingered double-tap does not litter.
    case discardTooShort
    /// Long enough but essentially silent: fail `no_speech`, so an empty recording
    /// does not sail into `mlx_whisper` and come back a hallucination.
    case rejectSilent
}

/// Gates a finished recording before transcription on two axes: a minimum duration
/// and an energy floor. Pure logic — the caller measures `duration` and `peak`
/// during capture and asks the guard what to do.
///
/// The thresholds are first-pass values, meant to be tuned against real recordings;
/// they are deliberately conservative so the guard never rejects genuine speech.
public struct RecordingGuard: Sendable {
    /// Recordings shorter than this are accidental taps. A deliberate thought runs
    /// well over a second; an errant double-tap-to-start-then-stop is sub-second.
    public let minimumDuration: TimeInterval
    /// Peak sample amplitude (0…1, max absolute sample seen) below which the
    /// recording counts as silence. Speech peaks far above this; a quiet room's
    /// noise floor stays under it.
    public let silencePeak: Float

    public init(minimumDuration: TimeInterval = 1.0, silencePeak: Float = 0.02) {
        self.minimumDuration = minimumDuration
        self.silencePeak = silencePeak
    }

    /// Decide the recording's fate. Duration is checked first: a too-short tap is
    /// always discarded, never surfaced as a `no_speech` failure.
    public func evaluate(duration: TimeInterval, peak: Float) -> GuardDecision {
        guard duration >= minimumDuration else { return .discardTooShort }
        guard peak >= silencePeak else { return .rejectSilent }
        return .accept
    }
}

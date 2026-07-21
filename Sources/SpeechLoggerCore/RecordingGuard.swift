import Foundation

/// The dual guard's verdict on a finished recording.
public enum GuardDecision: Sendable, Equatable {
    /// Long enough and loud enough: encode it and queue it.
    case accept
    /// Below the minimum duration: an accidental tap. Discard silently: it never
    /// becomes a log item, so a fat-fingered double-tap does not litter.
    case discardTooShort
    /// No speech in it: discard silently, at any duration (#46). An accidental
    /// double-tap you noticed and stopped is not an error worth a line in the log,
    /// and duration cannot tell that accident from a dead microphone — the dead
    /// microphone is detected directly instead (#45). Discarding also keeps digital
    /// silence out of `mlx_whisper`, which hallucinates on it.
    case discardSilent
}

/// Gates a finished recording before transcription on two axes: a minimum duration
/// and a windowed energy test. Pure logic — the caller measures during capture and
/// asks the guard what to do.
///
/// The energy verdict is *the fraction of ~20 ms windows above a floor*, not a
/// running peak and not a global average. A peak lets one key click, cough or door
/// slam carry an otherwise empty recording into transcription, and the accidental
/// double-tap this guard exists to discard contains a key click by construction. A
/// global average moves the other way: it dilutes as a recording grows, so a long
/// braindump full of thinking pauses would drift toward the silence verdict
/// precisely as it got longer. A fraction is duration-invariant.
///
/// The whole verdict lives here rather than in the capture, which carries only the
/// raw window sequence: what counts as a loud window and what fraction is enough are
/// both decided at this one seam, which is what makes offline calibration against
/// recorded fixtures possible at all.
///
/// The thresholds err deliberately toward accepting. The error costs are asymmetric:
/// a false "has speech" costs one hallucinated item the user sees and deletes, while
/// a false "silent" deletes real speech invisibly.
public struct RecordingGuard: Sendable {
    /// Recordings shorter than this are accidental taps. A deliberate thought runs
    /// well over a second; an errant double-tap-to-start-then-stop is sub-second.
    public let minimumDuration: TimeInterval
    /// RMS amplitude (0…1) at or above which one ~20 ms window counts as loud.
    ///
    /// Measured, not assumed (`RecordedEnergy`): in a silent room the loudest window
    /// of a right-Option double-tap — the gesture's own key click — is 0.005, since
    /// RMS over 20 ms spreads a ~1 ms transient thin. Speech at normal speaking
    /// distance runs to 0.26. The default sits 4x over the click and an order of
    /// magnitude under speech.
    public let loudWindowFloor: Float
    /// The fraction of windows that must be loud for the recording to count as
    /// speech. Low enough that sparse speech across long pauses still passes, high
    /// enough that a lone transient does not.
    ///
    /// Measured: a silent double-tap puts **0%** of its windows over the floor, while
    /// the sparsest real sample — a 280 ms `manda` inside a 1 s recording — puts 27%.
    /// The default sits inside that gap, nearer the empty end.
    ///
    /// It cannot go much lower without failing the case it exists for. The shortest
    /// recording that survives the duration floor is 1 s, or 50 windows, so a
    /// threshold of 2% would accept a recording whose *single* loud window is one
    /// transient. At 5% a lone spike is still discarded there, and the sparsest
    /// measured speech clears the bar five times over.
    public let minimumLoudFraction: Double

    public init(
        minimumDuration: TimeInterval = 1.0,
        loudWindowFloor: Float = 0.02,
        minimumLoudFraction: Double = 0.05
    ) {
        self.minimumDuration = minimumDuration
        self.loudWindowFloor = loudWindowFloor
        self.minimumLoudFraction = minimumLoudFraction
    }

    /// Decide the recording's fate from its duration and its per-window energies.
    /// Duration is checked first, so a too-short tap reads as `discardTooShort`
    /// whatever its energy — both verdicts discard, and the distinction is for the
    /// reader, not for the outcome.
    public func evaluate(duration: TimeInterval, windowEnergies: [Float]) -> GuardDecision {
        guard duration >= minimumDuration else { return .discardTooShort }
        // Measuring nothing is not measuring silence. An empty sequence means the
        // capture could not read the device's sample format at all, which says
        // nothing about whether the audio holds speech — and the audio itself may be
        // perfectly good. Keeping it costs a hallucinated item at worst; discarding
        // it would delete a whole braindump on the strength of a broken measurement,
        // which is the one error this guard must not make.
        guard !windowEnergies.isEmpty else { return .accept }
        let loud = windowEnergies.reduce(into: 0) { count, energy in
            if energy >= loudWindowFloor { count += 1 }
        }
        let fraction = Double(loud) / Double(windowEnergies.count)
        return fraction >= minimumLoudFraction ? .accept : .discardSilent
    }
}

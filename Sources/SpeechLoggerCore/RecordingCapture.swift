import Foundation

/// What a finished recording produced: the temp wav plus what the guard needs to judge
/// it — how long it ran, what it received, and what it measured. The wav is deleted once
/// the mp3 exists.
public struct RecordingCapture: Sendable, Equatable {
    /// The window energy is measured over. Fixed, and accumulated across the audio
    /// tap's buffers rather than per buffer: the tap's buffer size is a hint, not a
    /// guarantee. Dictation is the binding constraint — a 350 ms utterance yields ~17
    /// windows at this size, against ~4 at the tap's requested buffer size, and a
    /// fraction over 4 samples is too coarse to trust.
    public static let windowDuration: TimeInterval = 0.02

    /// The native wav streamed to a temp file during capture.
    public let wav: URL
    /// Recording length in seconds.
    public let duration: TimeInterval
    /// How many frames the capture actually *received* from the device.
    ///
    /// Carried alongside the duration it derives from, because the two are different
    /// facts and only one of them survives the arithmetic: a capture that received
    /// nothing has `duration == 0`, which is indistinguishable from an accidental tap
    /// and used to be discarded as one, deleting the braindump with no trace (#54).
    /// Zero here is a dead capture, at any duration and whatever the windows say.
    public let frames: Int
    /// RMS amplitude (0…1) of each `windowDuration` window, in order. The raw
    /// sequence, not a pre-computed verdict: what counts as loud and what fraction is
    /// enough are `RecordingGuard`'s to decide, which keeps the whole speech verdict
    /// at one seam and lets a sequence recorded from a real microphone be replayed as
    /// a test fixture (#46).
    ///
    /// Empty means the capture *measured nothing*, which is not the same as measuring
    /// silence, and — when `frames` is non-zero — not the same as receiving nothing
    /// either. See `RecordingGuard.evaluate`.
    public let windowEnergies: [Float]

    public init(wav: URL, duration: TimeInterval, frames: Int, windowEnergies: [Float]) {
        self.wav = wav
        self.duration = duration
        self.frames = frames
        self.windowEnergies = windowEnergies
    }
}

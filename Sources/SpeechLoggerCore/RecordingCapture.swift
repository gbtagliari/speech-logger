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

    /// The 16 kHz mono wav streamed to a temp file during capture (`CaptureState.format`).
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
    /// How many times the recorder had to rebuild its audio engine to keep this capture
    /// alive (#63). Zero on every healthy device.
    ///
    /// A rebuild is the recorder's answer to an engine that stopped under the capture or
    /// stayed running while delivering nothing, and it is not free: it means the engine's
    /// binding to the hardware did not hold on its own. Non-zero is therefore the
    /// positive tell, available at capture time, that the device was not delivering —
    /// what `deviceBindingFailed` reports and `RecordingGuard` reads.
    ///
    /// It is also the difference between the two failures the recording stage can name:
    /// a dead capture with rebuilds behind it names the device, one without them does
    /// not, because nothing observed says the device was at fault.
    public let engineRestarts: Int
    /// The input device this capture was opened against, as it names itself
    /// ("soundcore Life Q30"), or nil when it does not.
    ///
    /// Carried for one purpose: a recording-stage failure the user can act on. "The
    /// microphone delivered no audio" sends them looking; naming the headset tells them
    /// which one to take off.
    public let deviceName: String?

    /// What a device that publishes no name is called in a message someone might read.
    /// One home, so the recorder's log line and the item's error say the same thing.
    public static let unnamedDevice = "the input device"

    /// The device as a message names it. Never nil, because a failure that cannot name
    /// the device still has to be a sentence.
    public var deviceLabel: String { deviceName ?? Self.unnamedDevice }

    /// Whether the engine could not bind the device for this capture (#59, #60, #63).
    ///
    /// Derived, not reported separately: the recorder rebuilding the engine at all *is*
    /// the binding failing, and a second flag saying so could only ever disagree with the
    /// count. It is what separates a **short** dead capture (a device that opened then
    /// dropped inside the warm-up window, delivering a handful of frames and a short
    /// all-zero sequence) from a fat-fingered double-tap, which look identical by
    /// duration and energy alone.
    public var deviceBindingFailed: Bool { engineRestarts > 0 }

    public init(
        wav: URL, duration: TimeInterval, frames: Int, windowEnergies: [Float],
        engineRestarts: Int = 0, deviceName: String? = nil
    ) {
        self.wav = wav
        self.duration = duration
        self.frames = frames
        self.windowEnergies = windowEnergies
        self.engineRestarts = engineRestarts
        self.deviceName = deviceName
    }
}

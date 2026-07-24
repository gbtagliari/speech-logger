import Foundation

/// The guard's verdict on a finished recording.
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
    /// The capture received nothing: no frame arrived, or every window read exactly
    /// zero. **A failure, not a silence** (#54) — the item lands `failed` at stage
    /// `recording` and is never discarded. Which reason it names is the caller's to
    /// decide from the capture: `device_unavailable` when the recorder had to rebuild its
    /// engine to try to make the device deliver, `empty_output` when it did not (#63).
    ///
    /// Digital zero is not a quiet room. A live microphone always measures a noise
    /// floor (0.0015 internal, 0.007 on a Bluetooth headset); exact zero throughout is
    /// the absence of a measurement. It happens when `AVAudioEngine` never binds the
    /// device it is pointed at — a Bluetooth headset whose HFP link is still coming up is
    /// the measured case (#63): nothing throws, and the capture comes back empty.
    ///
    /// It is visible on purpose. The user spoke, and the app owes them a line saying so
    /// — where discarding it as a short tap deleted a whole braindump with no trace.
    case failEmptyCapture
}

/// Gates a finished recording before transcription on three axes, in this order: what
/// the capture *received*, a minimum duration, and a windowed energy test. Pure logic —
/// the caller measures during capture and asks the guard what to do.
///
/// Received-nothing comes first and is the only axis that fails rather than discards.
/// A capture that got no frames measures 0.00 s, so any other ordering would report it
/// as an accidental tap and delete the recording invisibly (#54).
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
///
/// The duration floor is **one value per mode**, because the same clip means opposite
/// things in the two: a braindump is a thought being formed, so under a second it is
/// an errant double-tap; a dictation is `manda` or `commita`, 400–700 ms of entirely
/// legitimate speech, and holding it to the braindump floor would delete the mode's
/// whole point (#42).
public struct RecordingGuard: Sendable {
    /// Braindumps shorter than this are accidental taps. A deliberate thought runs
    /// well over a second; an errant double-tap-to-start-then-stop is sub-second.
    public let braindumpMinimumDuration: TimeInterval
    /// Dictations shorter than this are accidental holds. It sits just above the mode
    /// threshold `T` (250 ms), so a double-tap that crossed into dictation by accident
    /// still dies here, while the shortest utterance anyone dictates on purpose lives.
    /// The speech test is the second net either way.
    public let dictationMinimumDuration: TimeInterval
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
    /// How long a run of nothing but exact zeros a device is allowed before the sequence
    /// stops reading as a warm-up and starts reading as a dead capture. In windows, since
    /// that is what is being counted; the default is stated as the duration it comes from.
    ///
    /// Measured, and load-bearing: **every** real recording opens with a run of exact
    /// zeros while the device spins up — 37 windows on the silent double-tap, 34 on
    /// normal speech, 27 on the short utterance (`RecordedEnergy`), which is 0.54 s to
    /// 0.74 s of them. A recording shorter than its device's warm-up is *entirely* zeros
    /// while being perfectly healthy, so without this allowance a fat-fingered tap would
    /// come back as a `failed` item — the litter #46 exists to prevent.
    ///
    /// The default is one second: a third clear of the longest run measured, and the
    /// length of the braindump duration floor, so nothing that survives that floor is
    /// judged by a rule tuned for something shorter. It costs the ticket's case nothing —
    /// a capture that received no *frames* is caught before this, at any length.
    ///
    /// An **allowance**, not a minimum: a sequence has to run *past* it, which is why the
    /// comparison is the one exclusive boundary in this type.
    public let warmUpWindowAllowance: Int

    public init(
        braindumpMinimumDuration: TimeInterval = 1.0,
        dictationMinimumDuration: TimeInterval = 0.35,
        loudWindowFloor: Float = 0.02,
        minimumLoudFraction: Double = 0.05,
        // Derived rather than written as 50, so "one second" is the code and not a
        // comment that a later tuning of the window size could quietly falsify.
        warmUpWindowAllowance: Int = Int(1.0 / RecordingCapture.windowDuration)
    ) {
        self.braindumpMinimumDuration = braindumpMinimumDuration
        self.dictationMinimumDuration = dictationMinimumDuration
        self.loudWindowFloor = loudWindowFloor
        self.minimumLoudFraction = minimumLoudFraction
        self.warmUpWindowAllowance = warmUpWindowAllowance
    }

    /// The floor the gesture's mode earns.
    private func minimumDuration(for mode: ItemMode) -> TimeInterval {
        switch mode {
        case .braindump: return braindumpMinimumDuration
        case .dictation: return dictationMinimumDuration
        }
    }

    /// Decide the recording's fate from its mode, its duration, the frames it received
    /// and its per-window energies.
    ///
    /// **A dead capture is judged before anything else** (#54). Its duration is 0.00 s
    /// by arithmetic — frames over sample rate — so a duration-first ordering reported
    /// it as `discardTooShort` and made a lost braindump indistinguishable from a
    /// fat-fingered double-tap. Nothing about a capture that received nothing may be
    /// inferred from the length it appears to have.
    ///
    /// The one thing that verdict will not do is fire on a recording too short to have
    /// outlasted the device's warm-up, which is all exact zeros while being healthy —
    /// see `warmUpWindowAllowance`. A capture that received no frames is caught
    /// whatever its length; a capture that received *zeros* has to have run long enough
    /// for that to mean something.
    ///
    /// After that, duration comes before energy, so a too-short tap reads as
    /// `discardTooShort` whatever its energy — both verdicts discard, and the
    /// distinction is for the reader, not for the outcome.
    ///
    /// The measurements arrive loose rather than as the `RecordingCapture` they come
    /// from, on purpose: the capture also carries the wav's URL, and this seam is the one
    /// place the whole verdict is decided *without hardware*, replaying window sequences
    /// recorded from a real microphone as fixtures (#46). A file that has to exist for a
    /// threshold to be swept would cost more than the loose arguments do.
    ///
    /// `deviceBindingFailed` is the #60 discriminator: a positive tell, from the recorder,
    /// that the engine could not bind the device. Since #63 it is one thing — the recorder
    /// had to rebuild its engine mid-capture to try to make the device deliver — and never
    /// a sample-rate comparison, which on the device that produced these tickets is a
    /// comparison between a real rate and a fiction. It is what lets a **short** dead
    /// capture — a device that opened then dropped inside the warm-up window — be told
    /// apart from a fat-fingered tap, which duration alone cannot. It defaults false so a
    /// caller with no such signal, and every replayed fixture, is judged exactly as
    /// before.
    public func evaluate(
        mode: ItemMode, duration: TimeInterval, frames: Int, windowEnergies: [Float],
        deviceBindingFailed: Bool = false
    ) -> GuardDecision {
        if receivedNothing(
            frames: frames, windowEnergies: windowEnergies,
            deviceBindingFailed: deviceBindingFailed) {
            return .failEmptyCapture
        }
        guard duration >= minimumDuration(for: mode) else { return .discardTooShort }
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

    /// Whether the capture received nothing at all: no frame arrived, or frames arrived
    /// and every window they produced — enough of them to rule out a warm-up — read
    /// exactly zero.
    ///
    /// Two shapes of the same failure, because contention produces both: a tap that is
    /// never called, and a tap called with buffers of digital zero. The first is
    /// unconditional. The second is read off *exact* equality across the **whole**
    /// sequence, and only once the sequence is longer than `warmUpWindowAllowance` —
    /// every real recording opens with a run of exact zeros while the device warms up, so
    /// neither a leading run of them nor a whole short recording of them proves anything.
    /// One window that measured something proves the device was delivering, and the
    /// recording is then judged on its energy like any other.
    ///
    /// An empty sequence with frames received is the third case and is *not* this one:
    /// it means the capture could not read the device's sample format, which says
    /// nothing about the audio — see the note in `evaluate`.
    ///
    /// `deviceBindingFailed` opens a fourth shape (#60): a **short** all-zero capture the
    /// warm-up allowance would otherwise protect. When the recorder reports the engine
    /// could not bind the device, a run of nothing but exact zeros is a dead capture at
    /// *any* length — the binding failure supplies the proof the device was not
    /// delivering that duration cannot. It is required alongside the zeros, not on its
    /// own: a binding failure over an empty sequence stays a keep (no measurement is not
    /// a measurement of zero), and a binding failure over a sequence that measured
    /// anything is judged on its energy like any other.
    private func receivedNothing(
        frames: Int, windowEnergies: [Float], deviceBindingFailed: Bool
    ) -> Bool {
        if frames == 0 { return true }
        // `allSatisfy` is vacuously true on an empty sequence, so the two zero-run
        // checks below both qualify it: the binding-failure branch with an explicit
        // non-empty guard, the warm-up branch with its length guard.
        let allZero = windowEnergies.allSatisfy { $0 == 0 }
        if deviceBindingFailed, !windowEnergies.isEmpty, allZero { return true }
        guard windowEnergies.count > warmUpWindowAllowance else { return false }
        return allZero
    }
}

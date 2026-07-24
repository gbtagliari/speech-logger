import Testing

@testable import SpeechLoggerCore

/// The guard gates a recording *before* transcription: a too-short tap and a
/// recording with no speech in it are both discarded, leaving nothing behind, while a
/// capture that received nothing fails visibly (#54). It exists because `mlx_whisper`
/// hallucinates (`E aí`) on a recording with nothing in it.
///
/// This is the single seam where the whole speech verdict is decided, so the
/// scenarios the product cares about are exercised here against synthetic window
/// sequences rather than against audio (#46).
struct RecordingGuardTests {
    // The default guard's thresholds, referenced by name so a tuning change is
    // one edit there and none here.
    private let guardCheck = RecordingGuard()

    // MARK: - Synthetic window sequences

    /// ~20 ms windows of *exact* digital zero — the absence of a measurement, which is
    /// what a dead capture reads as. Not silence: for that, see `quietRoom`.
    private func digitalZero(windows: Int) -> [Float] {
        Array(repeating: 0, count: windows)
    }

    /// `windows` of near-silence (a quiet room's noise floor) with exactly `loud`
    /// windows of speech-level energy spread evenly through it.
    private func speech(loud: Int, in windows: Int, level: Float = 0.09) -> [Float] {
        precondition(loud <= windows, "cannot place \(loud) loud windows in \(windows)")
        var sequence = Array(repeating: Float(0.0008), count: windows)
        for index in 0..<loud {
            sequence[index * windows / loud] = level
        }
        return sequence
    }

    /// `windows` of a quiet room: a noise floor, never digital zero. A live microphone
    /// always reads *something* — measured at 0.0015 on the internal microphone and
    /// 0.007 on a Bluetooth headset (#54).
    private func quietRoom(windows: Int) -> [Float] {
        Array(repeating: 0.0006, count: windows)
    }

    /// Frames a live capture of `duration` would have delivered at 48 kHz. The exact
    /// count never matters to the guard — only that it is not zero — but passing a
    /// plausible one keeps each case readable as the recording it stands for.
    private func frames(_ duration: Double) -> Int {
        Int(duration * 48000)
    }

    // MARK: - Duration

    @Test("a sub-threshold tap is discarded, regardless of energy")
    func discardsTooShortLoud() {
        // Even a loud blip below the minimum duration is an accidental tap.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.2, frames: frames(0.2), windowEnergies: speech(loud: 10, in: 10)) == .discardTooShort)
    }

    @Test("duration is checked before energy, so the verdict is unambiguous")
    func durationWinsOverSilence() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.1, frames: frames(0.1), windowEnergies: quietRoom(windows: 5)) == .discardTooShort)
    }

    @Test("the minimum-duration boundary is inclusive of acceptance")
    func durationBoundaryInclusive() {
        let loud = speech(loud: 40, in: 50)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.999, frames: frames(0.999), windowEnergies: loud) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 1.0, frames: frames(1.0), windowEnergies: loud) == .accept)
    }

    // MARK: - The dead capture (#54)

    @Test("a capture that received no frames fails the item, in either mode", arguments: ItemMode.allCases)
    func zeroFramesFails(mode: ItemMode) {
        // Under microphone contention the engine resolves the input node to a phantom
        // format and then delivers nothing: the wav opens, the tap installs, the engine
        // starts, and not one frame arrives. Duration is 0.00 s by arithmetic, which
        // read as an accidental tap and deleted the braindump with no trace.
        #expect(guardCheck.evaluate(mode: mode, duration: 0, frames: 0, windowEnergies: []) == .failEmptyCapture)
    }

    @Test("a capture that received nothing is never reported as a short tap")
    func zeroFramesIsNotATooShortTap() {
        // The whole point of the verdict: a lost braindump must not be indistinguishable
        // from a fat-fingered double-tap. It is the ordering that guarantees it — the
        // duration floor cannot judge a dead capture first, at any duration.
        for duration in [0.0, 0.2, 8.0, 300.0] {
            #expect(guardCheck.evaluate(mode: .braindump, duration: duration, frames: 0, windowEnergies: []) == .failEmptyCapture)
        }
    }

    @Test("windows of exact digital zero are a dead capture, however long it ran", arguments: ItemMode.allCases)
    func exactZeroWindowsFail(mode: ItemMode) {
        // A live microphone never reads exactly zero *for a whole recording*: even a
        // silent room has a noise floor, and RMS over 20 ms of it is small but present.
        // Digital zero throughout is the absence of a measurement, not a quiet one (#54).
        #expect(guardCheck.evaluate(mode: mode, duration: 8.0, frames: frames(8.0), windowEnergies: digitalZero(windows: 400)) == .failEmptyCapture)
        #expect(guardCheck.evaluate(mode: mode, duration: 300, frames: frames(300), windowEnergies: digitalZero(windows: 15000)) == .failEmptyCapture)
    }

    @Test("a recording too short to outlast the device's warm-up is not a dead capture")
    func warmUpZerosAreNotADeadCapture() {
        // The measured shape that makes this rule dangerous: every recording opens with
        // 27–37 windows of exact zero while the device spins up, so a capture shorter
        // than the warm-up is *entirely* zeros while being perfectly healthy. It must
        // still discard the way it always did — a fat-fingered tap that comes back as a
        // `failed` item is the litter #46 exists to prevent.
        let tap = digitalZero(windows: 20)  // 0.4 s: inside every warm-up run measured
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.4, frames: frames(0.4), windowEnergies: tap) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.4, frames: frames(0.4), windowEnergies: tap) == .discardSilent)
    }

    @Test("the warm-up allowance clears the longest run any real recording opens with")
    func warmUpAllowanceClearsTheMeasuredRuns() {
        // The allowance is measured, not guessed, and the fixtures are what measure it.
        // If a future recording lands here with a longer warm-up, or the allowance is
        // tuned under one, this fails before a healthy recording is reported as dead.
        let longestRun = [
            RecordedEnergy.silentDoubleTap, RecordedEnergy.normalSpeech,
            RecordedEnergy.shortUtterance,
        ].map { $0.prefix { $0 == 0 }.count }.max()!
        #expect(longestRun == 37)
        #expect(RecordingGuard().warmUpWindowAllowance > longestRun)
    }

    @Test("the warm-up allowance is never shorter than the braindump duration floor")
    func warmUpAllowanceCoversTheBraindumpFloor() {
        // Two constants tuned independently, with a load-bearing relation between them:
        // a recording long enough to survive the braindump floor must never be judged by
        // a rule calibrated for something shorter. Asserted here, in the shape the
        // dictation floor's own ordering uses, so a tuning that opens the gap fails
        // before it ships rather than in the field.
        let allowance = Double(guardCheck.warmUpWindowAllowance) * RecordingCapture.windowDuration
        #expect(allowance >= guardCheck.braindumpMinimumDuration)
    }

    @Test("the warm-up allowance is injectable and exclusive of the boundary")
    func warmUpAllowanceInjectable() {
        // At exactly the allowance the sequence is still a candidate warm-up; one window
        // past it, nothing but zeros is a dead capture.
        let lenient = RecordingGuard(warmUpWindowAllowance: 10)
        #expect(lenient.evaluate(mode: .braindump, duration: 8.0, frames: frames(8.0), windowEnergies: digitalZero(windows: 10)) == .discardSilent)
        #expect(lenient.evaluate(mode: .braindump, duration: 8.0, frames: frames(8.0), windowEnergies: digitalZero(windows: 11)) == .failEmptyCapture)
    }

    @Test("one window above digital zero is a quiet room, not a dead capture")
    func oneNonZeroWindowIsAMeasurement() {
        // The boundary between "received nothing" and "received silence". A single
        // window that read *anything* proves the device was delivering, so the recording
        // is judged on its energy like any other — and discarded as silent.
        var sequence = digitalZero(windows: 400)
        sequence[200] = 0.0006
        #expect(guardCheck.evaluate(mode: .braindump, duration: 8.0, frames: frames(8.0), windowEnergies: sequence) == .discardSilent)
    }

    // MARK: - The short dead capture (#60)

    @Test("a short all-zero capture from a device that would not bind fails, in either mode", arguments: ItemMode.allCases)
    func shortDeadCaptureFails(mode: ItemMode) {
        // The gap #54 left: a device that opens then drops inside the warm-up window
        // delivers a handful of frames and a short all-zero sequence, so it is a warm-up
        // by length and a fat-fingered tap by every other measure. The one thing that
        // tells it apart is that the engine could not bind the device — the #59 rate
        // mismatch, a positive tell the device was not delivering. Given that, a short
        // all-zero capture is dead, whatever its length.
        let dead = digitalZero(windows: 18)  // 0.36 s: inside every warm-up run measured
        #expect(guardCheck.evaluate(mode: mode, duration: 0.36, frames: frames(0.36), windowEnergies: dead, deviceBindingFailed: true) == .failEmptyCapture)
    }

    @Test("a short all-zero tap on a device that bound normally still discards, no litter")
    func shortTapWithoutBindingFailureDiscards() {
        // The acceptance criterion the fix must not break: a genuine sub-floor accidental
        // tap has no binding failure, so the warm-up allowance still protects it and it
        // discards silently the way it always did. Only the binding signal promotes a
        // short all-zero capture to a failure.
        let tap = digitalZero(windows: 18)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.36, frames: frames(0.36), windowEnergies: tap, deviceBindingFailed: false) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.36, frames: frames(0.36), windowEnergies: tap, deviceBindingFailed: false) == .discardSilent)
    }

    @Test("the binding signal never overrides a capture that measured something")
    func bindingFailureDoesNotFailARecordingThatMeasured() {
        // The signal only bites in combination with all-zero windows. A device that
        // recovered — bound badly but then delivered real speech — is judged on its
        // energy like any other, and accepted. The failure is "received nothing", not
        // "bound badly": one loud window is proof the device delivered.
        let utterance = speech(loud: 12, in: 20)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.4, frames: frames(0.4), windowEnergies: utterance, deviceBindingFailed: true) == .accept)
    }

    @Test("the binding signal does not fail an empty window sequence")
    func bindingFailureDoesNotFailEmptyWindows() {
        // Frames arrived, no window closed: the capture could not read the device's
        // sample format at all, which says nothing about whether the audio holds speech
        // — the audio may be fine. That stays a keep even under a binding failure; the
        // signal fails a capture that measured *zeros*, not one that measured nothing.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 5.0, frames: frames(5.0), windowEnergies: [], deviceBindingFailed: true) == .accept)
    }

    @Test("a replayed short dead capture fails only with the binding signal", arguments: ItemMode.allCases)
    func replaysShortDeadCapture(mode: ItemMode) {
        // The measured signature of the 2026-07-24 headset drop: short, all zero, a
        // handful of frames. It discards as an accidental tap on its own — the litter #46
        // guards against — and fails only once the guard is told the device would not bind.
        let dead = RecordedEnergy.shortDeadCapture
        #expect(guardCheck.evaluate(mode: mode, duration: 0.36, frames: frames(0.36), windowEnergies: dead, deviceBindingFailed: false) != .failEmptyCapture)
        #expect(guardCheck.evaluate(mode: mode, duration: 0.36, frames: frames(0.36), windowEnergies: dead, deviceBindingFailed: true) == .failEmptyCapture)
    }

    // MARK: - The five scenarios (#46)

    @Test("a silent room is discarded, not failed")
    func discardsQuietRoom() {
        // 5 minutes of nothing said leaves nothing behind: no item, no litter. The
        // device was live throughout — this is measured silence, not a dead capture.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 300, frames: frames(300), windowEnergies: quietRoom(windows: 15000)) == .discardSilent)
    }

    @Test("silence apart from one transient spike is discarded")
    func discardsSingleSpike() {
        // The accidental double-tap this ticket exists to discard *contains* a key
        // click by construction, inches from the microphone. A running peak would
        // have let this through to be transcribed into a hallucination.
        var sequence = quietRoom(windows: 100)
        sequence[42] = 0.35
        #expect(guardCheck.evaluate(mode: .braindump, duration: 2.0, frames: frames(2.0), windowEnergies: sequence) == .discardSilent)
    }

    @Test("sustained speech is accepted")
    func acceptsSustainedSpeech() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 8.0, frames: frames(8.0), windowEnergies: speech(loud: 300, in: 400)) == .accept)
    }

    @Test("a long recording with sparse speech is not diluted into a silence verdict")
    func acceptsSparseSpeechInLongRecording() {
        // A braindump full of thinking pauses: 5 minutes, a fifth of it speech. A
        // global RMS would average this toward the floor precisely as the recording
        // grows; a fraction of windows does not move with length.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 300, frames: frames(300), windowEnergies: speech(loud: 3000, in: 15000)) == .accept)
    }

    @Test("a 350 ms dictation is accepted on the energy test")
    func accepts350msDictation() {
        // `manda`, `commita`: a legitimate dictation, ~17 windows at 20 ms — the
        // binding constraint on the window size, since ~4 windows would be too
        // coarse a fraction to trust.
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.35, frames: frames(0.35), windowEnergies: speech(loud: 12, in: 17)) == .accept)
    }

    // MARK: - One floor per mode (#42)

    @Test("a dictation just over its floor survives, while the same clip dies as a braindump")
    func floorIsPerMode() {
        // The whole reason the floor is parameterised: `manda` / `commita` / `sim, pode`
        // are 400–700 ms of legitimate speech in one mode and an errant double-tap in
        // the other, and only the gesture can tell them apart.
        let utterance = speech(loud: 12, in: 20)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.4, frames: frames(0.4), windowEnergies: utterance) == .accept)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.4, frames: frames(0.4), windowEnergies: utterance) == .discardTooShort)
    }

    @Test("the dictation floor stays above the mode threshold, whatever either is tuned to")
    func dictationFloorClearsTheModeThreshold() {
        // Two constants in two types, tuned independently on-device, with a
        // load-bearing ordering between them: below `T` the floor would accept every
        // hold that was long enough to be *labeled* a dictation. Asserted here so a
        // tuning that opens that hole fails before it ships, not in the field.
        #expect(RecordingGuard().dictationMinimumDuration > HotkeyDetector().holdThreshold)
    }

    @Test("a hold that crossed T by accident still dies as too short")
    func dictationFloorRejectsABarelyCrossedHold() {
        // 350 ms is just over `T` (250 ms), so the gap between "held long enough to be
        // labeled a dictation" and "held long enough to be one" is not a hole.
        let loud = speech(loud: 8, in: 15)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.3, frames: frames(0.3), windowEnergies: loud) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.35, frames: frames(0.35), windowEnergies: loud) == .accept)
    }

    @Test("each mode's floor is injectable on its own")
    func floorsAreInjectable() {
        let strict = RecordingGuard(braindumpMinimumDuration: 2.0, dictationMinimumDuration: 1.0)
        let loud = speech(loud: 40, in: 50)
        #expect(strict.evaluate(mode: .braindump, duration: 1.5, frames: frames(1.5), windowEnergies: loud) == .discardTooShort)
        #expect(strict.evaluate(mode: .dictation, duration: 1.5, frames: frames(1.5), windowEnergies: loud) == .accept)
    }

    // MARK: - Duration invariance

    @Test("the verdict depends on the fraction of loud windows, not on the count")
    func verdictIsDurationInvariant() {
        let short = guardCheck.evaluate(mode: .braindump, duration: 2.0, frames: frames(2.0), windowEnergies: speech(loud: 20, in: 100))
        let long = guardCheck.evaluate(mode: .braindump, duration: 20.0, frames: frames(20.0), windowEnergies: speech(loud: 200, in: 1000))
        #expect(short == .accept)
        #expect(short == long)
    }

    // MARK: - Thresholds

    @Test("the loud-window floor is injectable and inclusive of loudness")
    func loudWindowFloorInjectable() {
        let sequence = Array(repeating: Float(0.05), count: 100)
        let strict = RecordingGuard(loudWindowFloor: 0.06, minimumLoudFraction: 0.5)
        let lenient = RecordingGuard(loudWindowFloor: 0.05, minimumLoudFraction: 0.5)
        #expect(strict.evaluate(mode: .braindump, duration: 5, frames: frames(5), windowEnergies: sequence) == .discardSilent)
        #expect(lenient.evaluate(mode: .braindump, duration: 5, frames: frames(5), windowEnergies: sequence) == .accept)
    }

    @Test("the loud-window fraction is injectable and inclusive of acceptance")
    func loudFractionInjectable() {
        let sequence = speech(loud: 10, in: 100)  // exactly 10%
        let strict = RecordingGuard(loudWindowFloor: 0.02, minimumLoudFraction: 0.11)
        let lenient = RecordingGuard(loudWindowFloor: 0.02, minimumLoudFraction: 0.10)
        #expect(strict.evaluate(mode: .braindump, duration: 5, frames: frames(5), windowEnergies: sequence) == .discardSilent)
        #expect(lenient.evaluate(mode: .braindump, duration: 5, frames: frames(5), windowEnergies: sequence) == .accept)
    }

    // MARK: - Replayed real recordings

    @Test("a real silent double-tap is discarded: its key click never clears the floor")
    func replaysSilentDoubleTap() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 3.34, frames: frames(3.34), windowEnergies: RecordedEnergy.silentDoubleTap) == .discardSilent)
    }

    @Test("a replayed dead capture fails the item, in either mode", arguments: ItemMode.allCases)
    func replaysDeadCapture(mode: ItemMode) {
        // The measured signature of a capture under microphone contention: every window
        // exactly zero, whatever the recording's length (#54). It is a failure, and the
        // one verdict it must never be is `discardTooShort`.
        #expect(guardCheck.evaluate(mode: mode, duration: 5.0, frames: frames(5.0), windowEnergies: RecordedEnergy.deadCapture) == .failEmptyCapture)
    }

    @Test("a real recording's warm-up zeros are not read as a dead capture")
    func recordedWarmUpZerosAreNotADeadCapture() {
        // Every recording on this machine opens with a run of exact zeros — 37 windows
        // on the silent double-tap, 34 on normal speech, 27 on the short utterance —
        // while the device warms up. The dead-capture verdict reads the *whole*
        // sequence, so a leading run of them cannot fail a recording that then went on
        // to measure something.
        #expect(RecordedEnergy.silentDoubleTap.prefix(37).allSatisfy { $0 == 0 })
        #expect(guardCheck.evaluate(mode: .braindump, duration: 3.34, frames: frames(3.34), windowEnergies: RecordedEnergy.silentDoubleTap) != .failEmptyCapture)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 6.40, frames: frames(6.40), windowEnergies: RecordedEnergy.normalSpeech) == .accept)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 1.04, frames: frames(1.04), windowEnergies: RecordedEnergy.shortUtterance) == .accept)
    }

    @Test("real speech at normal speaking distance is accepted")
    func replaysNormalSpeech() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 6.40, frames: frames(6.40), windowEnergies: RecordedEnergy.normalSpeech) == .accept)
    }

    @Test("a real 280 ms utterance is accepted on the energy test")
    func replaysShortUtterance() {
        #expect(guardCheck.evaluate(mode: .dictation, duration: 1.04, frames: frames(1.04), windowEnergies: RecordedEnergy.shortUtterance) == .accept)
    }

    @Test("the real samples stay on their own side even with the thresholds pushed hard")
    func recordedSamplesLeaveMargin() {
        // The gap the defaults sit in, asserted rather than left to a comment. Real
        // speech still reads as speech with the floor at 5x the default and the
        // fraction at 2x (it puts 14% of its windows over 0.1); a real silent
        // double-tap still reads as silence with the floor at a fifth of the default
        // and the fraction at a fifth (its lone click is 0.6% of the recording). If a
        // future tuning closes that gap, this fails before a recording is deleted in
        // the field.
        let strict = RecordingGuard(loudWindowFloor: 0.1, minimumLoudFraction: 0.10)
        #expect(strict.evaluate(mode: .braindump, duration: 6.40, frames: frames(6.40), windowEnergies: RecordedEnergy.normalSpeech) == .accept)
        let lenient = RecordingGuard(loudWindowFloor: 0.004, minimumLoudFraction: 0.01)
        #expect(lenient.evaluate(mode: .braindump, duration: 3.34, frames: frames(3.34), windowEnergies: RecordedEnergy.silentDoubleTap) == .discardSilent)
    }

    @Test("a lone transient is discarded even in the shortest recording that survives duration")
    func spikeDiscardedAtTheShortestRecording() {
        // The fraction floor is weakest here and nowhere else: 1.0 s is 50 windows, so
        // one loud window is 2% of the recording — the largest a single transient can
        // ever be. It must still lose.
        var sequence = quietRoom(windows: 50)
        sequence[25] = 0.4
        #expect(guardCheck.evaluate(mode: .braindump, duration: 1.0, frames: frames(1.0), windowEnergies: sequence) == .discardSilent)
    }

    @Test("a recording that measured nothing, but received frames, is kept")
    func acceptsEmptyWindowSequence() {
        // Frames arrived and no window closed: the capture could not read the device's
        // sample format at all. That says nothing about whether the audio holds speech,
        // and the audio may be fine — deleting a braindump on the strength of a broken
        // measurement is the one error this guard must not make. It is the frames, not
        // the windows, that separate this from a capture that received nothing (#54).
        #expect(guardCheck.evaluate(mode: .braindump, duration: 5.0, frames: frames(5.0), windowEnergies: []) == .accept)
    }
}

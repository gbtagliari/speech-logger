import Testing

@testable import SpeechLoggerCore

/// The dual guard gates a recording *before* transcription: a too-short tap and a
/// recording with no speech in it are both discarded, leaving nothing behind. It
/// exists because `mlx_whisper` hallucinates (`E aí`) on digital silence.
///
/// This is the single seam where the whole speech verdict is decided, so the
/// scenarios the product cares about are exercised here against synthetic window
/// sequences rather than against audio (#46).
struct RecordingGuardTests {
    // The default guard's thresholds, referenced by name so a tuning change is
    // one edit there and none here.
    private let guardCheck = RecordingGuard()

    // MARK: - Synthetic window sequences

    /// ~20 ms windows of digital silence.
    private func silence(windows: Int) -> [Float] {
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

    // MARK: - Duration

    @Test("a sub-threshold tap is discarded, regardless of energy")
    func discardsTooShortLoud() {
        // Even a loud blip below the minimum duration is an accidental tap.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.2, windowEnergies: speech(loud: 10, in: 10)) == .discardTooShort)
    }

    @Test("duration is checked before energy, so the verdict is unambiguous")
    func durationWinsOverSilence() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.1, windowEnergies: silence(windows: 5)) == .discardTooShort)
    }

    @Test("the minimum-duration boundary is inclusive of acceptance")
    func durationBoundaryInclusive() {
        let loud = speech(loud: 40, in: 50)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.999, windowEnergies: loud) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 1.0, windowEnergies: loud) == .accept)
    }

    // MARK: - The five scenarios (#46)

    @Test("digital silence is discarded, not failed")
    func discardsDigitalSilence() {
        // 5 minutes of nothing leaves nothing behind: no item, no litter.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 300, windowEnergies: silence(windows: 15000)) == .discardSilent)
    }

    @Test("silence apart from one transient spike is discarded")
    func discardsSingleSpike() {
        // The accidental double-tap this ticket exists to discard *contains* a key
        // click by construction, inches from the microphone. A running peak would
        // have let this through to be transcribed into a hallucination.
        var sequence = silence(windows: 100)
        sequence[42] = 0.35
        #expect(guardCheck.evaluate(mode: .braindump, duration: 2.0, windowEnergies: sequence) == .discardSilent)
    }

    @Test("sustained speech is accepted")
    func acceptsSustainedSpeech() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 8.0, windowEnergies: speech(loud: 300, in: 400)) == .accept)
    }

    @Test("a long recording with sparse speech is not diluted into a silence verdict")
    func acceptsSparseSpeechInLongRecording() {
        // A braindump full of thinking pauses: 5 minutes, a fifth of it speech. A
        // global RMS would average this toward the floor precisely as the recording
        // grows; a fraction of windows does not move with length.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 300, windowEnergies: speech(loud: 3000, in: 15000)) == .accept)
    }

    @Test("a 350 ms dictation is accepted on the energy test")
    func accepts350msDictation() {
        // `manda`, `commita`: a legitimate dictation, ~17 windows at 20 ms — the
        // binding constraint on the window size, since ~4 windows would be too
        // coarse a fraction to trust.
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.35, windowEnergies: speech(loud: 12, in: 17)) == .accept)
    }

    // MARK: - One floor per mode (#42)

    @Test("a dictation just over its floor survives, while the same clip dies as a braindump")
    func floorIsPerMode() {
        // The whole reason the floor is parameterised: `manda` / `commita` / `sim, pode`
        // are 400–700 ms of legitimate speech in one mode and an errant double-tap in
        // the other, and only the gesture can tell them apart.
        let utterance = speech(loud: 12, in: 20)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.4, windowEnergies: utterance) == .accept)
        #expect(guardCheck.evaluate(mode: .braindump, duration: 0.4, windowEnergies: utterance) == .discardTooShort)
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
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.3, windowEnergies: loud) == .discardTooShort)
        #expect(guardCheck.evaluate(mode: .dictation, duration: 0.35, windowEnergies: loud) == .accept)
    }

    @Test("each mode's floor is injectable on its own")
    func floorsAreInjectable() {
        let strict = RecordingGuard(braindumpMinimumDuration: 2.0, dictationMinimumDuration: 1.0)
        let loud = speech(loud: 40, in: 50)
        #expect(strict.evaluate(mode: .braindump, duration: 1.5, windowEnergies: loud) == .discardTooShort)
        #expect(strict.evaluate(mode: .dictation, duration: 1.5, windowEnergies: loud) == .accept)
    }

    // MARK: - Duration invariance

    @Test("the verdict depends on the fraction of loud windows, not on the count")
    func verdictIsDurationInvariant() {
        let short = guardCheck.evaluate(mode: .braindump, duration: 2.0, windowEnergies: speech(loud: 20, in: 100))
        let long = guardCheck.evaluate(mode: .braindump, duration: 20.0, windowEnergies: speech(loud: 200, in: 1000))
        #expect(short == .accept)
        #expect(short == long)
    }

    // MARK: - Thresholds

    @Test("the loud-window floor is injectable and inclusive of loudness")
    func loudWindowFloorInjectable() {
        let sequence = Array(repeating: Float(0.05), count: 100)
        let strict = RecordingGuard(loudWindowFloor: 0.06, minimumLoudFraction: 0.5)
        let lenient = RecordingGuard(loudWindowFloor: 0.05, minimumLoudFraction: 0.5)
        #expect(strict.evaluate(mode: .braindump, duration: 5, windowEnergies: sequence) == .discardSilent)
        #expect(lenient.evaluate(mode: .braindump, duration: 5, windowEnergies: sequence) == .accept)
    }

    @Test("the loud-window fraction is injectable and inclusive of acceptance")
    func loudFractionInjectable() {
        let sequence = speech(loud: 10, in: 100)  // exactly 10%
        let strict = RecordingGuard(loudWindowFloor: 0.02, minimumLoudFraction: 0.11)
        let lenient = RecordingGuard(loudWindowFloor: 0.02, minimumLoudFraction: 0.10)
        #expect(strict.evaluate(mode: .braindump, duration: 5, windowEnergies: sequence) == .discardSilent)
        #expect(lenient.evaluate(mode: .braindump, duration: 5, windowEnergies: sequence) == .accept)
    }

    // MARK: - Replayed real recordings

    @Test("a real silent double-tap is discarded: its key click never clears the floor")
    func replaysSilentDoubleTap() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 3.34, windowEnergies: RecordedEnergy.silentDoubleTap) == .discardSilent)
    }

    @Test("real speech at normal speaking distance is accepted")
    func replaysNormalSpeech() {
        #expect(guardCheck.evaluate(mode: .braindump, duration: 6.40, windowEnergies: RecordedEnergy.normalSpeech) == .accept)
    }

    @Test("a real 280 ms utterance is accepted on the energy test")
    func replaysShortUtterance() {
        #expect(guardCheck.evaluate(mode: .dictation, duration: 1.04, windowEnergies: RecordedEnergy.shortUtterance) == .accept)
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
        #expect(strict.evaluate(mode: .braindump, duration: 6.40, windowEnergies: RecordedEnergy.normalSpeech) == .accept)
        let lenient = RecordingGuard(loudWindowFloor: 0.004, minimumLoudFraction: 0.01)
        #expect(lenient.evaluate(mode: .braindump, duration: 3.34, windowEnergies: RecordedEnergy.silentDoubleTap) == .discardSilent)
    }

    @Test("a lone transient is discarded even in the shortest recording that survives duration")
    func spikeDiscardedAtTheShortestRecording() {
        // The fraction floor is weakest here and nowhere else: 1.0 s is 50 windows, so
        // one loud window is 2% of the recording — the largest a single transient can
        // ever be. It must still lose.
        var sequence = silence(windows: 50)
        sequence[25] = 0.4
        #expect(guardCheck.evaluate(mode: .braindump, duration: 1.0, windowEnergies: sequence) == .discardSilent)
    }

    @Test("a recording that measured nothing is kept, not deleted")
    func acceptsEmptyWindowSequence() {
        // An empty sequence means the capture could not read the device's sample
        // format at all. That says nothing about whether the audio holds speech, and
        // the audio may be fine — deleting a braindump on the strength of a broken
        // measurement is the one error this guard must not make.
        #expect(guardCheck.evaluate(mode: .braindump, duration: 5.0, windowEnergies: []) == .accept)
    }
}

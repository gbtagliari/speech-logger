import Testing

@testable import SpeechLoggerCore

/// The dual guard gates recording *before* transcription: a too-short tap is
/// discarded silently; a long-but-silent recording fails `no_speech`. It exists
/// because `mlx_whisper` hallucinates (`E aí`) on digital silence. Pure decision
/// logic over `(duration, peak)`.
struct RecordingGuardTests {
    // The default guard's thresholds, referenced by name so a tuning change is
    // one edit here and there.
    private let guardCheck = RecordingGuard()

    @Test("a normal-length recording with speech is accepted")
    func acceptsNormalRecording() {
        #expect(guardCheck.evaluate(duration: 8.0, peak: 0.4) == .accept)
    }

    @Test("a sub-threshold tap is discarded, regardless of energy")
    func discardsTooShortLoud() {
        // Even a loud blip below the minimum duration is an accidental tap.
        #expect(guardCheck.evaluate(duration: 0.2, peak: 0.9) == .discardTooShort)
    }

    @Test("a too-short and silent tap is discarded, not failed (duration wins)")
    func tooShortTakesPrecedenceOverSilence() {
        // Order matters: a fat-fingered double-tap should never litter the log as
        // a `failed` item — it is discarded before the energy test is consulted.
        #expect(guardCheck.evaluate(duration: 0.1, peak: 0.0) == .discardTooShort)
    }

    @Test("a long-but-silent recording is rejected as no-speech")
    func rejectsLongSilence() {
        #expect(guardCheck.evaluate(duration: 12.0, peak: 0.001) == .rejectSilent)
    }

    @Test("the minimum-duration boundary is inclusive of acceptance")
    func durationBoundaryInclusive() {
        let g = RecordingGuard(minimumDuration: 1.0, silencePeak: 0.02)
        #expect(g.evaluate(duration: 0.999, peak: 0.5) == .discardTooShort)
        #expect(g.evaluate(duration: 1.0, peak: 0.5) == .accept)
    }

    @Test("the silence-floor boundary is inclusive of acceptance")
    func silenceBoundaryInclusive() {
        let g = RecordingGuard(minimumDuration: 1.0, silencePeak: 0.02)
        #expect(g.evaluate(duration: 5.0, peak: 0.019) == .rejectSilent)
        #expect(g.evaluate(duration: 5.0, peak: 0.02) == .accept)
    }
}

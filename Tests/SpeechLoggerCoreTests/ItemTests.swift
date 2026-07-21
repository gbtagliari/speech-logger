import Foundation
import Testing

@testable import SpeechLoggerCore

/// The two per-item affordances the panel and the pipeline controller both read off
/// an item's state: retry (resume from where it died) and reprocess (run the whole
/// thing again from the audio). They are near-twins today and diverge on `organized`,
/// so both are pinned here rather than inferred from each other.
struct ItemTests {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(
        _ state: ItemState,
        mode: ItemMode = .braindump,
        error: ItemError? = nil,
        stoppedAt: StoppedAt? = nil
    ) -> Item {
        Item(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            meta: ItemMeta(
                state: state, mode: mode, created: created, error: error, stoppedAt: stoppedAt))
    }

    private func error(at stage: Stage) -> ItemError {
        ItemError(stage: stage, reason: .cliError, detail: nil, at: created)
    }

    // MARK: - Retry

    @Test("a death off the recording stage is retryable", arguments: [Stage.transcription, .pass1, .pass2])
    func failedOffRecordingIsRetryable(stage: Stage) {
        #expect(item(.failed, error: error(at: stage)).isRetryable)
        #expect(item(.cancelled, stoppedAt: StoppedAt(stage: stage, at: created)).isRetryable)
    }

    @Test("a recording-stage death is not retryable: there is nothing to resume")
    func recordingDeathIsNotRetryable() {
        #expect(!item(.failed, error: error(at: .recording)).isRetryable)
        #expect(!item(.cancelled, stoppedAt: StoppedAt(stage: .recording, at: created)).isRetryable)
    }

    @Test("an organized item is not retryable: nothing died, so there is no stage to resume from")
    func organizedIsNotRetryable() {
        #expect(!item(.organized).isRetryable)
    }

    // MARK: - Reprocess (#24)

    @Test("an organized item is reprocessable: the escape hatch for a fluent-but-wrong pass")
    func organizedIsReprocessable() {
        // The failure #24 documents: the item reached `organized` with no error and the
        // wrong content, so retry has no stage to offer and only a full re-run recovers it.
        #expect(item(.organized).isReprocessable)
    }

    @Test(
        "a death off the recording stage is reprocessable: the audio survived",
        arguments: [Stage.transcription, .pass1, .pass2])
    func failedOffRecordingIsReprocessable(stage: Stage) {
        #expect(item(.failed, error: error(at: stage)).isReprocessable)
        #expect(item(.cancelled, stoppedAt: StoppedAt(stage: stage, at: created)).isReprocessable)
    }

    @Test("a recording-stage death is not reprocessable: there is no audio to run again")
    func recordingDeathIsNotReprocessable() {
        #expect(!item(.failed, error: error(at: .recording)).isReprocessable)
        #expect(!item(.cancelled, stoppedAt: StoppedAt(stage: .recording, at: created)).isReprocessable)
    }

    @Test(
        "an in-flight item is not reprocessable: it is already running",
        arguments: [ItemState.recording, .queued, .transcribing, .organizing])
    func inFlightIsNotReprocessable(state: ItemState) {
        #expect(!item(state).isReprocessable)
    }

    // MARK: - Dictation (#41)

    @Test(
        "a dictation is retryable from a transcription death: the audio is retained",
        arguments: [ItemState.failed, .cancelled])
    func dictationIsRetryableFromTranscriptionDeath(state: ItemState) {
        let dead =
            state == .failed
            ? item(.failed, mode: .dictation, error: error(at: .transcription))
            : item(
                .cancelled, mode: .dictation,
                stoppedAt: StoppedAt(stage: .transcription, at: created))
        #expect(dead.isRetryable)
    }

    @Test("a dictation that died recording is not retryable, exactly like a braindump")
    func dictationRecordingDeathIsNotRetryable() {
        #expect(!item(.failed, mode: .dictation, error: error(at: .recording)).isRetryable)
    }

    @Test("a dictation is never reprocessable: there is no LLM run to start over")
    func dictationIsNeverReprocessable() {
        // The one place retry and reprocess disagree for the mode: a dead dictation
        // offers retry (re-transcribe the retained audio) but never reprocess, which
        // exists only to re-run the two passes that never ran here.
        let dead = item(.failed, mode: .dictation, error: error(at: .transcription))
        #expect(dead.isRetryable)
        #expect(!dead.isReprocessable)
        #expect(!item(.transcribed, mode: .dictation).isReprocessable)
        #expect(
            !item(.cancelled, mode: .dictation, stoppedAt: StoppedAt(stage: .transcription, at: created))
                .isReprocessable)
    }
}

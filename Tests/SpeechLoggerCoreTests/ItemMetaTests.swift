import Foundation
import Testing

@testable import SpeechLoggerCore

/// `meta.json` is the only file that represents `recording` and `failed` and the
/// timeline of an item (ADR-0003). These pin its shape, its immutable transition
/// helpers, and that it round-trips through the on-disk JSON form.
struct ItemMetaTests {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)
    private let at = Date(timeIntervalSince1970: 1_700_000_050)

    @Test("a new item starts at recording with created set and no transitions")
    func recordingStart() {
        let meta = ItemMeta.recording(created: created)
        #expect(meta.state == .recording)
        #expect(meta.created == created)
        #expect(meta.transitions.isEmpty)
        #expect(meta.duration == nil)
        #expect(meta.error == nil)
        #expect(meta.stoppedAt == nil)
        #expect(meta.schemaVersion == ItemMeta.currentSchemaVersion)
    }

    @Test("advancing returns a new meta and never mutates the original (immutability)")
    func advancingIsImmutable() {
        let start = ItemMeta.recording(created: created)
        let queued = start.advancing(to: .queued, at: at, duration: 12.5)
        #expect(start.state == .recording) // original untouched
        #expect(queued.state == .queued)
        #expect(queued.duration == 12.5)
        #expect(queued.timestamp(of: .queued) == at)
        #expect(queued.timestamp(of: .recording) == created)
    }

    @Test("duration carries forward once set")
    func durationCarriesForward() {
        let queued = ItemMeta.recording(created: created).advancing(to: .queued, at: at, duration: 9)
        let transcribing = queued.advancing(to: .transcribing, at: at)
        #expect(transcribing.duration == 9)
    }

    @Test("failing records the error and stamps the failed entry time")
    func failingCarriesError() {
        let meta = ItemMeta.recording(created: created)
            .advancing(to: .queued, at: at, duration: 3)
            .failing(stage: .transcription, reason: .noSpeech, detail: "silence", at: at)
        #expect(meta.state == .failed)
        #expect(meta.error?.stage == .transcription)
        #expect(meta.error?.reason == .noSpeech)
        #expect(meta.error?.detail == "silence")
        #expect(meta.error?.at == at)
        #expect(meta.stoppedAt == nil)
        #expect(meta.timestamp(of: .failed) == at)
    }

    @Test("cancelling records where it stopped and carries no error")
    func cancellingCarriesStoppedAt() {
        let meta = ItemMeta.recording(created: created)
            .advancing(to: .organizing, at: at)
            .cancelling(stage: .pass2, at: at)
        #expect(meta.state == .cancelled)
        #expect(meta.stoppedAt?.stage == .pass2)
        #expect(meta.stoppedAt?.at == at)
        #expect(meta.error == nil)
    }

    @Test("re-entering the happy path clears a prior error (retry semantics)")
    func advancingClearsError() {
        let retried = ItemMeta.recording(created: created)
            .failing(stage: .transcription, reason: .cliError, detail: nil, at: at)
            .advancing(to: .transcribing, at: at)
        #expect(retried.state == .transcribing)
        #expect(retried.error == nil)
    }

    @Test("meta round-trips through the ISO-8601 JSON form")
    func roundTripsThroughJSON() throws {
        let original = ItemMeta.recording(created: created)
            .advancing(to: .queued, at: at, duration: 4.2)
            .failing(stage: .pass1, reason: .emptyOutput, detail: "empty", at: at)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ItemMeta.self, from: try encoder.encode(original))
        #expect(decoded == original)
    }

    @Test("only organized, failed, and cancelled are terminal")
    func terminalStates() {
        #expect(ItemState.organized.isTerminal)
        #expect(ItemState.failed.isTerminal)
        #expect(ItemState.cancelled.isTerminal)
        #expect(!ItemState.recording.isTerminal)
        #expect(!ItemState.queued.isTerminal)
        #expect(!ItemState.transcribing.isTerminal)
        #expect(!ItemState.organizing.isTerminal)
    }
}

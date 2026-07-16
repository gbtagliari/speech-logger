import Foundation
import Testing

@testable import SpeechLoggerCore

/// A monotonic, injectable clock. Each `now()` returns a distinct instant 1 ms
/// later than the last, so every created item gets a unique, time-ordered ULID
/// and transition timestamps strictly increase.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        let value = current
        current += 0.001
        return value
    }
}

/// Behavioral tests for the persistence substrate (ADR-0003, ADR-0006): the state
/// transitions, the temp+rename invariant, list order, delete-to-Trash, and boot
/// recovery. Each test gets a fresh temp root (set up in `init`, removed in `deinit`).
final class ItemStoreTests {
    private let root: URL
    private let store: ItemStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
        let clock = Clock(start: Date(timeIntervalSince1970: 1_700_000_000))
        store = ItemStore(
            root: root,
            now: { clock.now() },
            makeID: { ULID.generate(timestamp: $0, randomByte: { 0 }) })
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Create

    @Test("create makes a ULID directory holding meta.json at recording")
    func createStartsAtRecording() throws {
        let item = try store.create()
        #expect(item.state == .recording)
        #expect(item.id.count == ULID.length)
        let metaURL = root.appendingPathComponent(item.id).appendingPathComponent(ItemFile.meta)
        #expect(FileManager.default.fileExists(atPath: metaURL.path))
        // The persisted meta matches what create returned.
        #expect(try store.meta(for: item.id) == item.meta)
    }

    // MARK: - Happy-path transitions

    @Test("an item walks recording -> queued -> transcribing -> organizing -> organized")
    func happyPathTransitions() throws {
        let item = try store.create()
        let id = item.id

        #expect(try store.markQueued(id, duration: 8.0).state == .queued)
        try store.write(Data("raw text".utf8), to: ItemFile.transcript, for: id)
        #expect(try store.markTranscribing(id).state == .transcribing)
        try store.write(Data("<del>uh</del> text".utf8), to: ItemFile.pass1, for: id)
        #expect(try store.markOrganizing(id).state == .organizing)
        let organized = try store.markOrganized(id, finalText: "final text")
        #expect(organized.state == .organized)

        let onDisk = try store.meta(for: id)
        #expect(onDisk.state == .organized)
        #expect(onDisk.duration == 8.0)
        // Timeline is monotonic across the transitions.
        #expect(onDisk.timestamp(of: .queued)! < onDisk.timestamp(of: .transcribing)!)
        #expect(onDisk.timestamp(of: .transcribing)! < onDisk.timestamp(of: .organizing)!)
        #expect(onDisk.timestamp(of: .organizing)! < onDisk.timestamp(of: .organized)!)
    }

    // MARK: - The invariant: final text present only in organized

    @Test("final text is copyable only when organized, never partial")
    func finalTextOnlyWhenOrganized() throws {
        let item = try store.create()
        // Even if a final.txt is somehow present, a non-organized item exposes nothing.
        try store.write(Data("leaked".utf8), to: ItemFile.final, for: item.id)
        #expect(try store.finalText(for: item.id) == nil)

        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        _ = try store.markOrganized(item.id, finalText: "the real final text")
        #expect(try store.finalText(for: item.id) == "the real final text")
    }

    @Test("markOrganized writes final.txt before flipping state")
    func finalWrittenBeforeStateFlips() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        _ = try store.markOrganized(item.id, finalText: "done")
        // Whenever the state is organized, the content is durably present.
        #expect(try store.meta(for: item.id).state == .organized)
        let final = try store.read(file: ItemFile.final, for: item.id)
        #expect(final != nil)
        #expect(String(decoding: final!, as: UTF8.self) == "done")
    }

    // MARK: - Temp + rename leaves no half-written file

    @Test("an atomic write leaves the full content and no leftover temp files")
    func atomicWriteIsClean() throws {
        let item = try store.create()
        let blob = Data(repeating: 0xAB, count: 200_000)
        try store.write(blob, to: ItemFile.audio, for: item.id)

        let readBack = try store.read(file: ItemFile.audio, for: item.id)
        #expect(readBack == blob)

        // The directory holds exactly meta.json and audio.mp3 — no stray temp file.
        let dir = root.appendingPathComponent(item.id)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == [ItemFile.audio, ItemFile.meta].sorted())
    }

    @Test("writing to a missing item throws itemNotFound")
    func writeToMissingItemThrows() {
        #expect(throws: StoreError.itemNotFound("nope")) {
            try store.write(Data(), to: ItemFile.transcript, for: "nope")
        }
    }

    // MARK: - Off-ramps

    @Test("fail records stage, reason, and detail")
    func failRecordsError() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        let failed = try store.fail(item.id, stage: .transcription, reason: .noSpeech, detail: "silent")
        #expect(failed.state == .failed)
        #expect(failed.error?.stage == .transcription)
        #expect(failed.error?.reason == .noSpeech)
        #expect(failed.error?.detail == "silent")
        #expect(try store.meta(for: item.id).error?.reason == .noSpeech)
    }

    @Test("cancel records the stop stage, distinct from a failure")
    func cancelRecordsStoppedAt() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        let cancelled = try store.cancel(item.id, stage: .pass2)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.stoppedAt?.stage == .pass2)
        #expect(cancelled.error == nil)
    }

    // MARK: - List order

    @Test("list is ordered by created")
    func listOrderedByCreated() throws {
        let first = try store.create()
        let second = try store.create()
        let third = try store.create()
        let ids = try store.list().map(\.id)
        #expect(ids == [first.id, second.id, third.id])
    }

    @Test("list skips directories without a decodable meta.json")
    func listSkipsJunk() throws {
        let item = try store.create()
        // A stray directory with no meta.json is not an item.
        let junk = root.appendingPathComponent("not-an-item", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        let ids = try store.list().map(\.id)
        #expect(ids == [item.id])
    }

    // MARK: - Delete to Trash

    @Test("delete removes the item directory and drops it from the list")
    func deleteTrashesItem() throws {
        let item = try store.create()
        let dir = root.appendingPathComponent(item.id)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        try store.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try store.list().isEmpty)
    }

    @Test("deleting a missing item throws itemNotFound")
    func deleteMissingThrows() {
        #expect(throws: StoreError.itemNotFound("gone")) {
            try store.delete("gone")
        }
    }

    // MARK: - Discard (silent hard-remove, not Trash)

    @Test("discard hard-removes a recording-stage item without going to Trash")
    func discardHardRemoves() throws {
        // A too-short accidental tap must not litter the log *or* the Trash.
        let item = try store.create()
        let dir = root.appendingPathComponent(item.id)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        try store.discard(item.id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try store.list().isEmpty)
    }

    @Test("discarding a missing item throws itemNotFound")
    func discardMissingThrows() {
        #expect(throws: StoreError.itemNotFound("gone")) {
            try store.discard("gone")
        }
    }

    // MARK: - Content-file URL (for in-place, streamed artifacts)

    @Test("contentURL points inside the item directory and requires the item to exist")
    func contentURLResolves() throws {
        let item = try store.create()
        let url = try store.contentURL(of: ItemFile.audio, for: item.id)
        #expect(url == root.appendingPathComponent(item.id).appendingPathComponent(ItemFile.audio))
        #expect(throws: StoreError.itemNotFound("nope")) {
            _ = try store.contentURL(of: ItemFile.audio, for: "nope")
        }
    }

    // MARK: - Boot recovery

    @Test("boot recovery marks every non-terminal item failed/interrupted")
    func recoveryMarksNonTerminal() throws {
        // recording orphan (nothing to resume)
        let recording = try store.create()
        // queued orphan
        let queued = try store.create()
        _ = try store.markQueued(queued.id, duration: 1)
        // transcribing orphan
        let transcribing = try store.create()
        _ = try store.markQueued(transcribing.id, duration: 1)
        _ = try store.markTranscribing(transcribing.id)
        // organized item (terminal, must be untouched)
        let organized = try store.create()
        _ = try store.markQueued(organized.id, duration: 1)
        _ = try store.markTranscribing(organized.id)
        _ = try store.markOrganizing(organized.id)
        _ = try store.markOrganized(organized.id, finalText: "done")

        let recovered = try store.recoverOrphans()
        #expect(Set(recovered.map(\.id)) == [recording.id, queued.id, transcribing.id])
        for item in recovered {
            #expect(item.meta.state == .failed)
            #expect(item.meta.error?.reason == .interrupted)
        }
        // The terminal item is untouched.
        #expect(try store.meta(for: organized.id).state == .organized)
        // A second pass finds nothing left to recover.
        #expect(try store.recoverOrphans().isEmpty)
    }

    @Test("a recording orphan is recovered at the recording stage and is not retryable")
    func recordingOrphanNotRetryable() throws {
        let item = try store.create()
        let recovered = try store.recoverOrphans()
        #expect(recovered.count == 1)
        #expect(recovered[0].meta.error?.stage == .recording)
        #expect(recovered[0].isRetryable == false)
        _ = item
    }

    @Test("a queued orphan is recovered at the transcription stage and is retryable")
    func queuedOrphanRetryableAtTranscription() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        let recovered = try store.recoverOrphans()
        #expect(recovered[0].meta.error?.stage == .transcription)
        #expect(recovered[0].isRetryable)
    }

    @Test("an organizing orphan with no pass1 pivot is recovered at pass1 (resume re-annotates)")
    func organizingOrphanWithoutPivotRecoveredAtPass1() throws {
        // No `pass1.txt` on disk: pass 1 itself was interrupted, so resume re-runs it
        // from the transcript.
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        let recovered = try store.recoverOrphans()
        #expect(recovered[0].meta.error?.stage == .pass1)
        #expect(recovered[0].isRetryable)
    }

    @Test("an organizing orphan with a pass1 pivot is recovered at pass2 (resume reuses the pivot)")
    func organizingOrphanWithPivotRecoveredAtPass2() throws {
        // `pass1.txt` exists: pass 1 finished and pass 2 was interrupted, so resume
        // must skip annotate and rewrite from the retained pivot (#22).
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        try store.write(Data("annotated pivot".utf8), to: ItemFile.pass1, for: item.id)
        let recovered = try store.recoverOrphans()
        #expect(recovered[0].meta.error?.stage == .pass2)
        #expect(recovered[0].isRetryable)
    }

    // MARK: - Retry re-entry (#22)

    @Test("requeueForRetry moves a failed item back to queued, preserving duration and clearing error")
    func requeueForRetryReenters() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 12.5)
        _ = try store.markTranscribing(item.id)
        _ = try store.fail(item.id, stage: .transcription, reason: .cliError, detail: "boom")

        let meta = try store.requeueForRetry(item.id)
        #expect(meta.state == .queued)
        #expect(meta.error == nil)  // the happy path is re-entered
        #expect(meta.duration == 12.5)  // the recording length survives, audio is reused
    }

    @Test("resumeForOrganizing moves a failed item back to the transcribing handoff, clearing error")
    func resumeForOrganizingReenters() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 3)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        _ = try store.fail(item.id, stage: .pass2, reason: .cliError, detail: "boom")

        let meta = try store.resumeForOrganizing(item.id)
        #expect(meta.state == .transcribing)  // the lane's handoff guard consumes this
        #expect(meta.error == nil)
    }

    @Test("resumeForOrganizing clears a cancelled item's stoppedAt on re-entry")
    func resumeClearsStoppedAt() throws {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 3)
        _ = try store.markTranscribing(item.id)
        _ = try store.markOrganizing(item.id)
        _ = try store.cancel(item.id, stage: .pass1)

        let meta = try store.resumeForOrganizing(item.id)
        #expect(meta.state == .transcribing)
        #expect(meta.stoppedAt == nil)
    }

    @Test("hasContent reports whether a stage artifact is on disk")
    func hasContentDetectsArtifacts() throws {
        let item = try store.create()
        #expect(!store.hasContent(ItemFile.pass1, for: item.id))
        try store.write(Data("pivot".utf8), to: ItemFile.pass1, for: item.id)
        #expect(store.hasContent(ItemFile.pass1, for: item.id))
    }
}

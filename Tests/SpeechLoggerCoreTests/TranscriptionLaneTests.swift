import Foundation
import Testing

@testable import SpeechLoggerCore

/// The serial FIFO lane (ADR-0006): items are transcribed one at a time in arrival
/// order (`queued` → `transcribing` → transcript written), and each failure maps to
/// the right reason. The `mlx_whisper` seam is faked so these run without the binary;
/// a guarded end-to-end test drives a real transcription through the lane.
struct TranscriptionLaneTests {
    // MARK: - Happy path

    @Test("a queued item goes queued -> transcribing, its transcript is written, and it hands off")
    func transcribesAQueuedItem() async throws {
        let store = try makeStore()
        let id = try queuedItem(in: store)
        let collector = Collector()
        let lane = TranscriptionLane(
            store: store,
            transcriber: FakeTranscriber(log: CallLog(), writesOutput: true),
            onStateChange: { collector.bumpState() },
            onTranscribed: { collector.addTranscribed($0) })

        await lane.enqueue(id)
        await lane.waitUntilIdle()

        // The item is `transcribing` (organization, the consumer, is a later ticket).
        #expect(try store.meta(for: id).state == .transcribing)
        // The raw transcript is on disk.
        #expect(try store.read(file: ItemFile.transcript, for: id) != nil)
        // It handed off exactly once, with its id.
        #expect(collector.transcribed == [id])
        #expect(collector.stateChanges >= 1)
    }

    // MARK: - Mode routing (#41)

    @Test("a dictation rests at transcribed and never hands off to organization")
    func dictationRestsAtTranscribed() async throws {
        let store = try makeStore()
        let id = try queuedItem(in: store, mode: .dictation)
        let collector = Collector()
        let lane = TranscriptionLane(
            store: store,
            transcriber: FakeTranscriber(log: CallLog(), writesOutput: true),
            onStateChange: { collector.bumpState() },
            onTranscribed: { collector.addTranscribed($0) })

        await lane.enqueue(id)
        await lane.waitUntilIdle()

        // The transcript is the output: the item is terminal, with no organization to run.
        #expect(try store.meta(for: id).state == .transcribed)
        #expect(try store.read(file: ItemFile.transcript, for: id) != nil)
        // The handoff never fires, which is the mode's defining property: the seam that
        // reaches the LLM is not crossed, so zero passes can run.
        #expect(collector.transcribed.isEmpty)
    }

    @Test("a retried dictation reaches transcribed, not a second failure")
    func retriedDictationReachesTranscribed() async throws {
        // The path the mode's retry actually takes: a dead dictation is requeued onto
        // this same lane, so it must land on the dictation terminal the second time too.
        let store = try makeStore()
        let id = try queuedItem(in: store, mode: .dictation)
        _ = try store.markTranscribing(id)
        _ = try store.fail(id, stage: .transcription, reason: .cliError, detail: "boom")
        _ = try store.requeueForRetry(id)

        let collector = Collector()
        let lane = TranscriptionLane(
            store: store,
            transcriber: FakeTranscriber(log: CallLog(), writesOutput: true),
            onStateChange: { collector.bumpState() },
            onTranscribed: { collector.addTranscribed($0) })

        await lane.enqueue(id)
        await lane.waitUntilIdle()

        #expect(try store.meta(for: id).state == .transcribed)
        #expect(try store.meta(for: id).error == nil)
        #expect(collector.transcribed.isEmpty)
    }

    // MARK: - Serial FIFO

    @Test("three items transcribe in arrival order, one at a time (never two at once)")
    func processesSeriallyInOrder() async throws {
        let store = try makeStore()
        let ids = try (0..<3).map { _ in try queuedItem(in: store) }
        let log = CallLog()
        let lane = TranscriptionLane(store: store, transcriber: FakeTranscriber(log: log, writesOutput: true))

        for id in ids { await lane.enqueue(id) }
        await lane.waitUntilIdle()

        // Arrival order preserved, and the lane never ran two transcriptions at once.
        #expect(await log.order == ids)
        #expect(await log.maxConcurrent == 1)
    }

    // MARK: - Failure mapping

    @Test(
        "an empty transcript fails the item empty_output at the transcription stage",
        arguments: [
            (TranscriptionError.emptyOutput(detail: ""), FailureReason.emptyOutput),
            (TranscriptionError.launchFailed("no binary"), FailureReason.missingBinary),
            (TranscriptionError.io("disk full"), FailureReason.cliError),
        ])
    func mapsFailures(error: TranscriptionError, expected: FailureReason) async throws {
        let store = try makeStore()
        let id = try queuedItem(in: store)
        let collector = Collector()
        let lane = TranscriptionLane(
            store: store,
            transcriber: ThrowingTranscriber(error: error),
            onTranscribed: { collector.addTranscribed($0) })

        await lane.enqueue(id)
        await lane.waitUntilIdle()

        let meta = try store.meta(for: id)
        #expect(meta.state == .failed)
        #expect(meta.error?.stage == .transcription)
        #expect(meta.error?.reason == expected)
        // A failure never hands off to organization.
        #expect(collector.transcribed.isEmpty)
    }

    // MARK: - The queued guard

    @Test("an item that is no longer queued is skipped, not transcribed")
    func skipsANonQueuedItem() async throws {
        let store = try makeStore()
        let item = try store.create()
        // Cancelled before the lane picks it up: nothing to transcribe.
        _ = try store.cancel(item.id, stage: .transcription)
        let log = CallLog()
        let lane = TranscriptionLane(store: store, transcriber: FakeTranscriber(log: log, writesOutput: true))

        await lane.enqueue(item.id)
        await lane.waitUntilIdle()

        #expect(await log.order.isEmpty)  // never invoked mlx_whisper
        #expect(try store.meta(for: item.id).state == .cancelled)  // left untouched
    }

    // MARK: - Cancellation (the manual "stop" and graceful quit)

    @Test("stopping the transcribing item marks it cancelled at the transcription stage")
    func cancelTranscribingItem() async throws {
        let store = try makeStore()
        let id = try queuedItem(in: store)
        // A transcriber that blocks until its task is cancelled, standing in for a
        // long `mlx_whisper` run that `cancel` terminates.
        let lane = TranscriptionLane(store: store, transcriber: BlockingTranscriber())

        await lane.enqueue(id)
        try await waitUntil { (try? store.meta(for: id))?.state == .transcribing }
        await lane.cancel(id)
        await lane.waitUntilIdle()

        let meta = try store.meta(for: id)
        #expect(meta.state == .cancelled)  // cancelled, never failed
        #expect(meta.stoppedAt?.stage == .transcription)
    }

    @Test("stopping a queued item drops it from the lane and marks it cancelled, never transcribed")
    func cancelQueuedItem() async throws {
        let store = try makeStore()
        let blocker = try queuedItem(in: store)  // occupies the serial lane
        let waiting = try queuedItem(in: store)  // sits behind it in `queued`
        let log = CallLog()
        let lane = TranscriptionLane(store: store, transcriber: BlockingTranscriber(log: log))

        await lane.enqueue(blocker)
        await lane.enqueue(waiting)
        try await waitUntil { (try? store.meta(for: blocker))?.state == .transcribing }

        await lane.cancel(waiting)  // still queued behind the blocker
        #expect(try store.meta(for: waiting).state == .cancelled)
        #expect(try store.meta(for: waiting).stoppedAt?.stage == .transcription)

        await lane.cancel(blocker)  // release the lane so the test can finish
        await lane.waitUntilIdle()
        #expect(await log.order == [blocker])  // the cancelled item never transcribed
    }

    @Test("shutdown stops the in-flight transcription and drops the backlog (quit never blocks)")
    func shutdownStopsLane() async throws {
        let store = try makeStore()
        let blocker = try queuedItem(in: store)
        let waiting = try queuedItem(in: store)
        let lane = TranscriptionLane(store: store, transcriber: BlockingTranscriber())

        await lane.enqueue(blocker)
        await lane.enqueue(waiting)
        try await waitUntil { (try? store.meta(for: blocker))?.state == .transcribing }

        await lane.shutdown()
        await lane.waitUntilIdle()  // returns promptly: the blocker was killed

        // The in-flight item is cancelled; the dropped backlog item is left untouched
        // (the controller marks queued items on quit, not the lane's shutdown).
        #expect(try store.meta(for: blocker).state == .cancelled)
        #expect(try store.meta(for: waiting).state == .queued)
    }

    // MARK: - End-to-end (real mlx_whisper against a real sample)

    @Test(
        "a real queued item transcribes end-to-end through the lane",
        .enabled(if: SampleFixtures.transcriptionAvailable))
    func transcribesRealItemThroughLane() async throws {
        let store = try makeStore()
        let item = try store.create()
        // Stage the sample as the item's audio, exactly as the encoder would have.
        try FileManager.default.copyItem(
            at: SampleFixtures.caso02, to: try store.contentURL(of: ItemFile.audio, for: item.id))
        _ = try store.markQueued(item.id, duration: 17.3)

        let lane = TranscriptionLane(store: store, transcriber: Transcriber())
        await lane.enqueue(item.id)
        await lane.waitUntilIdle()

        #expect(try store.meta(for: item.id).state == .transcribing)
        let transcript = try #require(try store.read(file: ItemFile.transcript, for: item.id))
        let text = String(decoding: transcript, as: UTF8.self)
        #expect(text.contains("Packers"))  // the turbo model ran, not silent tiny
    }

    // MARK: - Fixtures & helpers

    /// A store rooted on a throwaway temp directory.
    private func makeStore() throws -> ItemStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ItemStore(root: root)
    }

    /// Create an item and move it to `queued`, the state the lane consumes.
    private func queuedItem(in store: ItemStore, mode: ItemMode = .braindump) throws -> String {
        let item = try store.create(mode: mode)
        _ = try store.markQueued(item.id, duration: 1.0)
        return item.id
    }
}

// MARK: - Test doubles for the `Transcribing` seam

/// Records the order of transcriptions and the peak concurrency the lane allowed.
private actor CallLog {
    private(set) var order: [String] = []
    private(set) var maxConcurrent = 0
    private var active = 0

    func begin(_ id: String) {
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        order.append(id)
    }

    func end() { active -= 1 }
}

/// Succeeds, optionally writing a transcript file, and yields repeatedly mid-run so a
/// (hypothetically) concurrent lane would reveal itself as `maxConcurrent > 1`.
private struct FakeTranscriber: Transcribing {
    let log: CallLog
    let writesOutput: Bool

    func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError) {
        let id = transcript.deletingLastPathComponent().lastPathComponent
        await log.begin(id)
        for _ in 0..<10 { await Task.yield() }
        if writesOutput { try? Data("raw transcript".utf8).write(to: transcript) }
        await log.end()
    }
}

/// Always throws the given error, without writing anything.
private struct ThrowingTranscriber: Transcribing {
    let error: TranscriptionError
    func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError) { throw error }
}

/// Blocks until its task is cancelled, then throws as a killed `mlx_whisper` would
/// (no output file). Stands in for a long transcription that `cancel`/`shutdown`
/// terminates, so the lane's cancellation path is exercised without the binary.
private struct BlockingTranscriber: Transcribing {
    let log: CallLog?
    init(log: CallLog? = nil) { self.log = log }

    func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError) {
        if let log { await log.begin(transcript.deletingLastPathComponent().lastPathComponent) }
        while !Task.isCancelled { await Task.yield() }
        throw TranscriptionError.emptyOutput(detail: "cancelled")
    }
}

/// A thread-safe sink for the lane's callbacks (they fire synchronously on the actor).
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _transcribed: [String] = []
    private var _stateChanges = 0

    func addTranscribed(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        _transcribed.append(id)
    }

    func bumpState() {
        lock.lock(); defer { lock.unlock() }
        _stateChanges += 1
    }

    var transcribed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _transcribed
    }

    var stateChanges: Int {
        lock.lock(); defer { lock.unlock() }
        return _stateChanges
    }
}

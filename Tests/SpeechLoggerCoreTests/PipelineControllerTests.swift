import Foundation
import Testing

@testable import SpeechLoggerCore

/// The cross-cutting controls (#22, ADR-0006): manual stop, resume-from-stage retry,
/// and a graceful quit that never blocks. Exercised over a real store on a temp
/// directory with the two lanes and the recording coordinator wired as the app wires
/// them, and the shell-outs faked so nothing touches a binary.
@MainActor struct PipelineControllerTests {
    // MARK: - Stop

    @Test("stop forwards to the organization lane: an organizing item lands cancelled")
    func stopCancelsOrganizing() async throws {
        let ctx = try Context()
        let id = try ctx.transcribedItem(transcript: Context.blockSentinel)
        await ctx.organization.organize(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .organizing }

        ctx.controller.stop(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .cancelled }

        let meta = try ctx.store.meta(for: id)
        #expect(meta.state == .cancelled)
        #expect(meta.stoppedAt?.stage == .pass1)
    }

    @Test("stop forwards to the transcription lane: a transcribing item lands cancelled")
    func stopCancelsTranscribing() async throws {
        let ctx = try Context()
        let id = try ctx.queuedItem()
        await ctx.transcription.enqueue(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .transcribing }

        ctx.controller.stop(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .cancelled }

        #expect(try ctx.store.meta(for: id).stoppedAt?.stage == .transcription)
    }

    // MARK: - Retry

    @Test("retry from the transcription stage re-transcribes and organizes to organized")
    func retryTranscriptionStage() async throws {
        let ctx = try Context()
        let id = try ctx.queuedItem(withAudio: true)  // the retained mp3 the retry reuses
        _ = try ctx.store.markTranscribing(id)
        _ = try ctx.store.fail(id, stage: .transcription, reason: .cliError, detail: "boom")

        ctx.controller.retry(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .organized }

        // The whole pipeline re-ran off the retained audio, reaching a final text.
        #expect(try ctx.store.finalText(for: id) != nil)
    }

    @Test("retry from pass2 resumes organization reusing the pivot, never re-annotating")
    func retryPass2ReusesPivot() async throws {
        let ctx = try Context()
        let id = try ctx.transcribedItem(transcript: "irrelevante")
        // A prior attempt left the annotated pivot; the item died at pass 2.
        try ctx.store.write(Data("PIVOT".utf8), to: ItemFile.pass1, for: id)
        _ = try ctx.store.markOrganizing(id)
        _ = try ctx.store.cancel(id, stage: .pass2)

        ctx.controller.retry(id)
        try await waitUntil { (try? ctx.store.meta(for: id))?.state == .organized }

        #expect(await ctx.organizer.annotateCalls == 0)  // pass 1 skipped
        #expect(try ctx.store.finalText(for: id) == FakeOrganizer.rewritten("PIVOT"))
    }

    @Test("retry of a recording-stage death is a no-op: nothing to resume, delete-only")
    func retryRecordingStageIsNoOp() async throws {
        let ctx = try Context()
        let item = try ctx.store.create()
        _ = try ctx.store.fail(item.id, stage: .recording, reason: .noSpeech, detail: "silent")

        ctx.controller.retry(item.id)
        // Give any (erroneous) async re-entry a chance to run, then assert it did not.
        try await Task.sleep(for: .milliseconds(50))
        #expect(try ctx.store.meta(for: item.id).state == .failed)
    }

    @Test("retry of a non-terminal item is a no-op")
    func retryNonTerminalIsNoOp() async throws {
        let ctx = try Context()
        let id = try ctx.queuedItem()  // still queued, not a retryable off-ramp
        ctx.controller.retry(id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try ctx.store.meta(for: id).state == .queued)
    }

    // MARK: - Graceful quit

    @Test("quit marks in-flight processing cancelled, discards the recording, and does not block")
    func quitGracefully() async throws {
        let ctx = try Context()

        // One item transcribing (blocked), one organizing (blocked), one recording.
        let transcribing = try ctx.queuedItem()
        await ctx.transcription.enqueue(transcribing)
        try await waitUntil { (try? ctx.store.meta(for: transcribing))?.state == .transcribing }

        let organizing = try ctx.transcribedItem(transcript: Context.blockSentinel)
        await ctx.organization.organize(organizing)
        try await waitUntil { (try? ctx.store.meta(for: organizing))?.state == .organizing }

        ctx.recording.start()  // a recording in progress
        #expect(ctx.recording.isRecording)
        let recordingID = try #require(try ctx.store.list().first { $0.state == .recording }).id

        await ctx.controller.quitGracefully()

        // In-flight processing is cancelled (retryable), the recording is gone silently.
        #expect(try ctx.store.meta(for: transcribing).state == .cancelled)
        #expect(try ctx.store.meta(for: organizing).state == .cancelled)
        #expect(!ctx.recording.isRecording)
        #expect(throws: StoreError.self) { try ctx.store.meta(for: recordingID) }
    }

    // MARK: - Fixtures

    /// The assembled pipeline: a real store on a temp root, the two lanes wired
    /// transcription→organization exactly as the app wires them, the recording
    /// coordinator over stub hardware, and the controller over all of it. Blocking
    /// fakes make the "in-flight" states reachable and cancellable.
    @MainActor private final class Context {
        /// A transcript that makes the fake organizer block in pass 1 until cancelled,
        /// so a test can hold an item in `organizing` and then stop/quit it.
        static let blockSentinel = "BLOCK"

        let root: URL
        let store: ItemStore
        let recording: RecordingCoordinator
        let transcription: TranscriptionLane
        let organization: OrganizationLane
        let organizer = RecordingOrganizer()
        let controller: PipelineController

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("items", isDirectory: true)
            let clock = Clock(start: Date(timeIntervalSince1970: 1_700_000_000))
            store = ItemStore(
                root: root,
                now: { clock.now() },
                makeID: { ULID.generate(timestamp: $0, randomByte: { 0 }) })

            let organization = OrganizationLane(store: store, organizer: organizer)
            self.organization = organization
            transcription = TranscriptionLane(
                store: store,
                transcriber: SwitchingTranscriber(),
                onTranscribed: { id in Task { await organization.organize(id) } })
            recording = RecordingCoordinator(
                store: store, recorder: StubRecorder(), encoder: StubEncoder())
            controller = PipelineController(
                store: store, recording: recording,
                transcription: transcription, organization: organization)
        }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        /// A fresh item moved to `queued`, the transcription lane's input. With
        /// `withAudio`, stage a dummy `audio.mp3` so the fake transcriber produces a
        /// transcript and completes; without it, the transcriber blocks until cancelled
        /// (standing in for a long in-flight run a test will stop/quit).
        func queuedItem(withAudio: Bool = false) throws -> String {
            let item = try store.create()
            if withAudio {
                try store.write(Data("mp3".utf8), to: ItemFile.audio, for: item.id)
            }
            _ = try store.markQueued(item.id, duration: 1)
            return item.id
        }

        /// A fresh item moved to `transcribing` with its transcript written, the
        /// organization lane's input.
        func transcribedItem(transcript: String) throws -> String {
            let id = try queuedItem()
            _ = try store.markTranscribing(id)
            try store.write(Data(transcript.utf8), to: ItemFile.transcript, for: id)
            return id
        }
    }
}

// MARK: - Test doubles

/// Writes a transcript and returns when the item's audio is on disk (a retry reusing
/// the retained mp3), and otherwise blocks until cancelled — standing in for a long
/// in-flight `mlx_whisper` run a test stops or quits.
private struct SwitchingTranscriber: Transcribing {
    func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError) {
        if FileManager.default.fileExists(atPath: audio.path) {
            try? Data("raw transcript".utf8).write(to: transcript)
            return
        }
        while !Task.isCancelled { await Task.yield() }
        throw TranscriptionError.emptyOutput(detail: "cancelled")
    }
}

/// Deterministic two-pass transform, recording whether pass 1 ran so a pass-2 resume
/// can prove it was skipped. Pass 1 blocks until cancelled when the transcript is the
/// block sentinel (so an organizing item can be stopped/quit); any other transcript
/// annotates and completes normally.
private actor RecordingOrganizer: Organizing {
    private(set) var annotateCalls = 0
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        if transcript == "BLOCK" {
            while !Task.isCancelled { await Task.yield() }
            throw .failed(stage: .pass1, reason: .cliError, detail: "cancelled")
        }
        annotateCalls += 1
        return "ANNOTATED[\(transcript)]"
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        FakeOrganizer.rewritten(annotated)
    }
}

private enum FakeOrganizer {
    static func rewritten(_ t: String) -> String { "REWRITTEN[\(t)]" }
}

/// Writes a real temp wav on `start`, returns a normal capture on `stop`.
@MainActor private final class StubRecorder: AudioRecording {
    private var wav: URL?
    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-rec-\(UUID().uuidString).wav")
        try Data("wav".utf8).write(to: url)
        wav = url
    }
    func stop() -> RecordingCapture {
        let url = wav!
        wav = nil
        return RecordingCapture(wav: url, duration: 8, peak: 0.4)
    }
}

/// Writes a dummy mp3 at the destination.
private struct StubEncoder: AudioEncoding {
    func encode(wav: URL, to mp3: URL) async throws { try Data("mp3".utf8).write(to: mp3) }
}

/// A monotonic, thread-safe injectable clock (1 ms per tick) for unique ordered ids.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        defer { current += 0.001 }
        return current
    }
}

/// Poll `condition` until it holds or the timeout elapses (then throw).
private func waitUntil(
    timeout: Double = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    struct WaitTimeout: Error {}
    throw WaitTimeout()
}

import Foundation
import Testing

@testable import SpeechLoggerCore

private enum StubError: Error { case micDenied, encodeFailed }

/// A recorder stub that writes a real temp wav on `start` (so the downstream
/// delete/encode has a file to act on) and returns a configurable capture on `stop`.
@MainActor private final class StubRecorder: AudioRecording {
    var throwOnStart = false
    var captureDuration: TimeInterval = 8.0
    /// Window energies the guard will read. Default: sustained speech.
    var captureEnergies: [Float] = Array(repeating: 0.09, count: 400)
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastWav: URL?
    private var currentWav: URL?

    func start() throws {
        startCount += 1
        if throwOnStart { throw StubError.micDenied }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-recorder-\(UUID().uuidString).wav")
        try Data("wav".utf8).write(to: url)
        currentWav = url
    }

    func stop() -> RecordingCapture {
        stopCount += 1
        let wav = currentWav!
        currentWav = nil
        lastWav = wav
        return RecordingCapture(wav: wav, duration: captureDuration, windowEnergies: captureEnergies)
    }
}

/// An encoder stub that either writes a dummy mp3 to the destination or throws.
private struct StubEncoder: AudioEncoding {
    var shouldFail = false
    func encode(wav: URL, to mp3: URL) async throws {
        if shouldFail { throw StubError.encodeFailed }
        try Data("mp3".utf8).write(to: mp3)
    }
}

/// A fake device query: the state is set by the test, and every read is counted so
/// "re-checked at the start of every recording" is observable rather than assumed.
@MainActor private final class StubMicrophone {
    var state: MicrophoneState = .usable
    private(set) var queryCount = 0

    func query() -> MicrophoneState {
        queryCount += 1
        return state
    }
}

/// A monotonic, thread-safe injectable clock: each `now()` is 1 ms after the last,
/// so every created item gets a unique, time-ordered id.
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

/// The orchestration seam (ADR-0006): exclusive recording, a hotkey that never
/// refuses, and the guard/encode outcomes as observable item state. Uses a real
/// store on a temp directory with stubbed hardware.
@MainActor struct RecordingCoordinatorTests {
    private let root: URL
    private let store: ItemStore
    private let recorder = StubRecorder()
    private let microphone = StubMicrophone()

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
        let clock = Clock(start: Date(timeIntervalSince1970: 1_700_000_000))
        store = ItemStore(
            root: root,
            now: { clock.now() },
            makeID: { ULID.generate(timestamp: $0, randomByte: { 0 }) })
    }

    private func makeCoordinator(encoder: StubEncoder = StubEncoder()) -> RecordingCoordinator {
        let microphone = self.microphone
        return RecordingCoordinator(
            store: store, recorder: recorder, encoder: encoder,
            microphone: { microphone.query() })
    }

    private func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    // MARK: - Start

    @Test("the hotkey starts a recording: an item is created at recording, mic opens")
    func startCreatesRecordingItem() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        #expect(coordinator.isRecording)
        #expect(recorder.startCount == 1)
        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .recording)
    }

    @Test("a start gesture from idle starts recording")
    func startGestureStarts() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.handle(.start)
        #expect(coordinator.isRecording)
        #expect(try store.list().count == 1)
    }

    @Test("recording is exclusive: a second start while recording is a no-op")
    func startIsExclusive() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.start()
        #expect(recorder.startCount == 1)
        #expect(try store.list().count == 1)
    }

    // MARK: - The accept path

    @Test("a normal recording encodes to mp3, lands queued, and the wav is deleted")
    func acceptQueuesAndDeletesWav() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 8.0
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(!coordinator.isRecording)
        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .queued)
        #expect(items[0].meta.duration == 8.0)
        // The retained mp3 exists; the temp wav is gone.
        let mp3 = try store.contentURL(of: ItemFile.audio, for: items[0].id)
        #expect(FileManager.default.fileExists(atPath: mp3.path))
        #expect(!FileManager.default.fileExists(atPath: recorder.lastWav!.path))
    }

    @Test("landing queued hands the item id to the transcription lane exactly once")
    func acceptFiresOnQueued() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var queued: [String] = []
        coordinator.onQueued = { queued.append($0) }
        recorder.captureDuration = 8.0
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        let items = try store.list()
        #expect(queued == [items[0].id])
    }

    @Test("a discarded recording never hands off to the lane")
    func nonAcceptDoesNotFireOnQueued() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var queued: [String] = []
        coordinator.onQueued = { queued.append($0) }
        // Too short: discarded, no handoff.
        recorder.captureDuration = 0.1
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        // Long but silent: discarded too, no handoff.
        recorder.captureDuration = 8.0
        recorder.captureEnergies = Array(repeating: 0.0, count: 400)
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(queued.isEmpty)
    }

    // MARK: - The hotkey never refuses

    @Test("a new recording starts even while the previous item is still queued")
    func hotkeyNeverRefuses() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        await coordinator.stop(mode: .braindump)  // item 1 -> queued
        #expect(!coordinator.isRecording)

        coordinator.start()  // a new recording, unblocked by the queued item
        #expect(coordinator.isRecording)
        #expect(recorder.startCount == 2)
        let states = try store.list().map(\.state)
        #expect(states.contains(.queued))
        #expect(states.contains(.recording))
    }

    // MARK: - The dual guard

    @Test("a too-short tap is discarded silently: no item survives")
    func tooShortDiscarded() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0.2
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(try store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recorder.lastWav!.path))
    }

    @Test("a silent recording leaves nothing behind, however long it ran")
    func silentDiscardedAtAnyDuration() async throws {
        defer { cleanup() }
        // 5 minutes of silence used to become a `failed` item, which is litter: an
        // accidental double-tap you noticed and stopped is not an error worth a line
        // in the log (#46). The dead microphone is detected directly instead (#45).
        for duration in [2.0, 300.0] {
            let coordinator = makeCoordinator()
            recorder.captureDuration = duration
            recorder.captureEnergies = Array(repeating: 0.0004, count: Int(duration / 0.02))
            coordinator.start()
            await coordinator.stop(mode: .braindump)
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: recorder.lastWav!.path))
        }
    }

    @Test("a recording that is silent apart from one transient spike is discarded")
    func singleSpikeDiscarded() async throws {
        defer { cleanup() }
        // The key click of the double-tap itself. A running peak would have carried
        // this into transcription and come back a hallucination.
        let coordinator = makeCoordinator()
        var energies = Array(repeating: Float(0.0004), count: 400)
        energies[120] = 0.4
        recorder.captureDuration = 8.0
        recorder.captureEnergies = energies
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(try store.list().isEmpty)
    }

    // MARK: - The mode the gesture earned (#42)

    @Test("the gesture's mode is what the item is recorded as, settled at the end")
    func stopStampsTheMode() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 2.0
        coordinator.start()
        // Mid-recording the item is unlabeled — a braindump, the default — because the
        // hold that decides it has not happened yet.
        #expect(try store.list()[0].meta.mode == .braindump)

        await coordinator.stop(mode: .dictation)

        let items = try store.list()
        #expect(items[0].state == .queued)
        #expect(items[0].meta.mode == .dictation)
    }

    @Test("a dictation just over its floor survives the same clip a braindump discards")
    func perModeDurationFloor() async throws {
        defer { cleanup() }
        // 400 ms of speech: `manda`, `commita`. Held, it is the mode's whole point;
        // toggled, it is a fat-fingered double-tap and leaves nothing behind.
        recorder.captureDuration = 0.4
        recorder.captureEnergies = Array(repeating: 0.09, count: 20)

        let dictating = makeCoordinator()
        dictating.start()
        await dictating.stop(mode: .dictation)
        let dictations = try store.list()
        #expect(dictations.count == 1)
        #expect(dictations[0].state == .queued)
        #expect(dictations[0].meta.mode == .dictation)

        let braindumping = makeCoordinator()
        braindumping.start()
        await braindumping.stop(mode: .braindump)
        #expect(try store.list().count == 1)  // nothing new survived
    }

    @Test("a stop gesture runs the whole stop, mode included")
    func stopGestureCarriesTheMode() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 2.0
        coordinator.start()
        coordinator.handle(.stop(.dictation))
        let store = self.store
        try await waitUntil { (try? store.list().first?.state) == .queued }
        #expect(try store.list()[0].meta.mode == .dictation)
    }

    // MARK: - Encode failure

    @Test("an encode failure lands the item failed with a cli_error")
    func encodeFailureFails() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator(encoder: StubEncoder(shouldFail: true))
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        let items = try store.list()
        #expect(items[0].state == .failed)
        #expect(items[0].meta.error?.reason == .cliError)
    }

    // MARK: - Mic failure and idle stop

    @Test("a mic that fails to start discards the item and reports, staying idle")
    func micStartFailureDiscards() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.throwOnStart = true
        var reported: Error?
        coordinator.onRecorderStartFailed = { reported = $0 }
        coordinator.start()
        #expect(!coordinator.isRecording)
        #expect(try store.list().isEmpty)
        #expect(reported != nil)
    }

    // MARK: - The microphone check

    /// Capturing while knowing nothing will arrive is manufacturing the loss on
    /// purpose: better to cost a moment now than a whole braindump later. Nothing is
    /// written, so there is no empty item to clean up afterwards either.
    @Test(
        "an unusable microphone refuses the recording rather than capturing silence",
        arguments: [MicrophoneState.permissionDenied, .noDevice, .silenced])
    func unusableMicrophoneRefuses(state: MicrophoneState) throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        microphone.state = state
        var refused: MicrophoneState?
        coordinator.onRecordingRefused = { refused = $0 }

        coordinator.start()

        #expect(!coordinator.isRecording)
        #expect(recorder.startCount == 0)  // the mic is never opened
        #expect(try store.list().isEmpty)
        #expect(refused == state)
    }

    /// The panel-open check is not enough: mute state changes between opening the panel
    /// and pressing the key, and the start of a recording is the only instant that
    /// actually matters.
    @Test("the device is re-checked at the start of every recording, not once")
    func deviceIsRecheckedOnEveryStart() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(microphone.queryCount == 1)

        // Muted between the two gestures: the second recording must catch it.
        microphone.state = .silenced
        coordinator.start()

        #expect(microphone.queryCount == 2)
        #expect(!coordinator.isRecording)
    }

    /// The refusal is reported and nothing else: no modal, no state change to recover
    /// from, and the next press of the hotkey is accepted exactly as before.
    @Test("a refusal leaves the hotkey working: the next start records once the mic is back")
    func refusalDoesNotBlockTheHotkey() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        microphone.state = .silenced
        coordinator.start()
        #expect(!coordinator.isRecording)

        microphone.state = .usable
        coordinator.start()

        #expect(coordinator.isRecording)
        #expect(recorder.startCount == 1)
        #expect(try store.list().count == 1)
    }

    @Test("stopping when not recording is a no-op")
    func stopWhenIdleNoOp() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        await coordinator.stop(mode: .braindump)
        #expect(recorder.stopCount == 0)
        #expect(try store.list().isEmpty)
    }
}

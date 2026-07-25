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
    /// Frames received, if the test cares. Default: what `captureDuration` implies at
    /// 48 kHz, so an ordinary capture is a live one and only a test that means to
    /// simulate a dead device (#54) sets it to zero.
    var captureFrames: Int?
    /// How many times the recorder had to rebuild its engine under the capture (#63).
    /// Default zero: an ordinary capture bound on the first try, and only a test
    /// simulating a device that would not stay bound sets it. Non-zero is what the guard
    /// reads as "the engine could not bind the device" (#60).
    var captureRestarts = 0
    /// The device the capture was opened against, for the failure that names it (#63).
    var captureDeviceName: String?
    /// The recorder's "audio is actually arriving" signal (#63). Fired by
    /// `deliverFirstFrame()`, never by `start()`: the whole point is that opening the
    /// mic and receiving audio are different events, seconds apart on a Bluetooth
    /// headset.
    var onAudioFlowing: (@MainActor () -> Void)?
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

    /// What a real recorder does the moment the capture's first buffer arrives.
    func deliverFirstFrame() { onAudioFlowing?() }

    func stop() -> RecordingCapture {
        stopCount += 1
        let wav = currentWav!
        currentWav = nil
        lastWav = wav
        return RecordingCapture(
            wav: wav, duration: captureDuration,
            frames: captureFrames ?? Int(captureDuration * 48000),
            windowEnergies: captureEnergies, engineRestarts: captureRestarts,
            deviceName: captureDeviceName)
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
        #expect(coordinator.isCapturing)
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
        #expect(coordinator.isCapturing)
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

    // MARK: - Nothing signals recording before the first frame (#63)

    /// The mic being open and audio arriving are two facts, and on a Bluetooth headset
    /// they are 1.0–1.6 s apart. The gesture grammar and exclusivity need the first one;
    /// everything the user can see must follow the second, or the clock runs over a
    /// capture that is receiving nothing.
    @Test("the gesture opens the mic, and nothing signals recording until audio arrives")
    func recordingSignalFollowsTheFirstFrame() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        #expect(coordinator.isCapturing)
        #expect(!coordinator.isRecording)

        recorder.deliverFirstFrame()
        #expect(coordinator.isRecording)
        #expect(coordinator.isCapturing)
    }

    @Test("the first frame fires a state change, so the glyph and the clock can follow it")
    func theFirstFrameFiresAStateChange() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var changes = 0
        coordinator.onStateChange = { changes += 1 }
        coordinator.start()
        let afterStart = changes

        recorder.deliverFirstFrame()
        #expect(changes == afterStart + 1)
    }

    @Test("a capture that never receives audio never signals recording, and still stops")
    func aDeadCaptureNeverSignalsRecording() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureFrames = 0
        coordinator.start()
        #expect(!coordinator.isRecording)

        await coordinator.stop(mode: .braindump)
        #expect(!coordinator.isRecording)
        #expect(!coordinator.isCapturing)
    }

    @Test("a discarded recording drops the signal too, so the glyph cannot stick on")
    func discardClearsTheRecordingSignal() throws {
        defer { cleanup() }
        // The graceful-quit path (ADR-0006). It bypasses `stop`, so it has to clear both
        // flags itself or the menubar would keep a live clock over a mic that is shut.
        let coordinator = makeCoordinator()
        coordinator.start()
        recorder.deliverFirstFrame()
        #expect(coordinator.isRecording)

        coordinator.discardIfRecording()
        #expect(!coordinator.isRecording)
        #expect(!coordinator.isCapturing)
    }

    @Test("a frame arriving after the recording is over signals nothing")
    func aLateFrameSignalsNothing() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        coordinator.start()
        recorder.deliverFirstFrame()
        await coordinator.stop(mode: .braindump)

        recorder.deliverFirstFrame()
        #expect(!coordinator.isRecording)
    }

    // MARK: - The accept path

    @Test("a normal recording encodes to mp3, lands queued, and the wav is deleted")
    func acceptQueuesAndDeletesWav() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 8.0
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(!coordinator.isCapturing)
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
        recorder.captureEnergies = Array(repeating: 0.0006, count: 400)
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
        #expect(!coordinator.isCapturing)

        coordinator.start()  // a new recording, unblocked by the queued item
        #expect(coordinator.isCapturing)
        #expect(recorder.startCount == 2)
        let states = try store.list().map(\.state)
        #expect(states.contains(.queued))
        #expect(states.contains(.recording))
    }

    // MARK: - The guard

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

    @Test("a discard reports what it measured, so it is not invisible everywhere at once")
    func discardReportsItsMeasurements() async throws {
        defer { cleanup() }
        // A discard leaves no item on purpose (#46), which left the whole verdict with
        // nowhere to be seen: a five-second braindump read as silence and vanished with
        // no item, no failure and no log line, and the only reason the cause was ever
        // found is that an energy dump happened to be switched on (#67). The verdict now
        // says what it measured, and the app target logs it.
        let coordinator = makeCoordinator()
        var discards: [DiscardedRecording] = []
        coordinator.onRecordingDiscarded = { discards.append($0) }
        recorder.captureDuration = 5.2
        recorder.captureEnergies = RecordedEnergy.silentDoubleTap
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(try store.list().isEmpty)
        #expect(discards.count == 1)
        let report = try #require(discards.first)
        // The same guard the coordinator was built with, so the logged floor is the one
        // the verdict was actually made against.
        let guardCheck = RecordingGuard()
        #expect(report.decision == .discardSilent)
        #expect(report.mode == .braindump)
        #expect(report.duration == 5.2)
        #expect(report.windows == RecordedEnergy.silentDoubleTap.count)
        #expect(report.peak == RecordedEnergy.silentDoubleTap.max())
        #expect(report.speech == guardCheck.measure(RecordedEnergy.silentDoubleTap))
        #expect(try #require(report.speech).loudFraction < guardCheck.minimumLoudFraction)
    }

    @Test("a discard with nothing measured carries no speech numbers")
    func discardWithoutWindowsCarriesNoMeasurement() async throws {
        defer { cleanup() }
        // A capture that closed no window has no floor and no fraction. The report says
        // so rather than carrying the bare cap next to a 0% nothing was counted for
        // (#67) — the log line would otherwise name a threshold no decision used.
        let coordinator = makeCoordinator()
        var discards: [DiscardedRecording] = []
        coordinator.onRecordingDiscarded = { discards.append($0) }
        recorder.captureDuration = 0.4
        recorder.captureEnergies = []
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(discards.map(\.decision) == [.discardTooShort])
        #expect(discards.first?.speech == nil)
    }

    @Test("an accepted recording reports no discard")
    func acceptReportsNoDiscard() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var discards: [DiscardedRecording] = []
        coordinator.onRecordingDiscarded = { discards.append($0) }
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(discards.isEmpty)
    }

    @Test("a too-short tap reports its own verdict, not the silent one")
    func shortTapReportsItsVerdict() async throws {
        defer { cleanup() }
        // The two discards are one outcome and two causes, and the log line is the only
        // place the difference is ever visible.
        let coordinator = makeCoordinator()
        var discards: [DiscardedRecording] = []
        coordinator.onRecordingDiscarded = { discards.append($0) }
        recorder.captureDuration = 0.4
        recorder.captureEnergies = Array(repeating: 0.09, count: 20)
        coordinator.start()
        await coordinator.stop(mode: .braindump)
        #expect(discards.map(\.decision) == [.discardTooShort])
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

    // MARK: - The dead capture (#54)

    /// The failure mode in practice, and the one the guard's verdicts exist to keep
    /// apart from an accidental tap: the device reports itself usable, the engine starts
    /// without throwing, and not one frame arrives. It used to leave nothing at all — no
    /// item, no error, no log line — however long the user had been speaking.
    @Test("a capture that received nothing lands failed, not discarded", arguments: ItemMode.allCases)
    func deadCaptureFails(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0  // frames / sampleRate, with no frames
        recorder.captureFrames = 0
        recorder.captureEnergies = []
        coordinator.start()
        await coordinator.stop(mode: mode)

        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .failed)
        #expect(items[0].meta.error?.stage == .recording)
        #expect(items[0].meta.error?.reason == .emptyOutput)
        #expect(items[0].meta.mode == mode)  // both modes, identically
        #expect(!FileManager.default.fileExists(atPath: recorder.lastWav!.path))
    }

    @Test("a capture whose windows are all exactly zero fails, at a full braindump's length")
    func deadCaptureWithZeroWindowsFails() async throws {
        defer { cleanup() }
        // The other shape of the same failure: buffers arrive and carry digital zero.
        // Long enough to clear every duration floor, so only the received-nothing axis
        // can catch it — and a real quiet room, which never reads exactly zero, still
        // discards.
        let coordinator = makeCoordinator()
        recorder.captureDuration = 300
        recorder.captureEnergies = Array(repeating: 0, count: 15000)
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .failed)
        #expect(items[0].meta.error?.reason == .emptyOutput)
    }

    @Test("a short dead capture from a device that would not bind lands failed (#60)", arguments: ItemMode.allCases)
    func shortDeadCaptureFails(mode: ItemMode) async throws {
        defer { cleanup() }
        // The gap #54 left and #60 closes: a device that opened then dropped inside the
        // warm-up window delivers a handful of frames and a short all-zero sequence,
        // which reads as an accidental tap by length and energy alone. The rebuilds the
        // recorder had to spend are what promote it to a visible failure.
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0.36
        recorder.captureFrames = Int(0.36 * 48000)
        recorder.captureEnergies = Array(repeating: 0, count: 18)
        recorder.captureRestarts = 3
        coordinator.start()
        await coordinator.stop(mode: mode)

        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .failed)
        #expect(items[0].meta.error?.stage == .recording)
        #expect(items[0].meta.error?.reason == .deviceUnavailable)
        #expect(items[0].meta.mode == mode)
    }

    @Test("the same short all-zero capture discards when the device bound normally (#60)")
    func shortTapWithoutBindingFailureDiscards() async throws {
        defer { cleanup() }
        // The acceptance criterion the fix must not break: without the binding signal a
        // genuine sub-floor tap is still an accidental tap, and leaves no item.
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0.36
        recorder.captureFrames = Int(0.36 * 48000)
        recorder.captureEnergies = Array(repeating: 0, count: 18)
        recorder.captureRestarts = 0
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(try store.list().isEmpty)
    }

    // MARK: - The device the recorder could not hold (#63)

    /// The end of the road for a Bluetooth headset that will not stay bound: the
    /// watchdog rebuilt the engine until its budget ran out and audio never came. It
    /// still fails visibly, but not as `empty_output` — that name is for a capture whose
    /// cause is unknown, and here the cause is known and has a name.
    @Test("a capture the engine had to be rebuilt for fails naming the device")
    func deadCaptureAfterRestartsNamesTheDevice() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0
        recorder.captureFrames = 0
        recorder.captureEnergies = []
        recorder.captureRestarts = 10
        recorder.captureDeviceName = "soundcore Life Q30"
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        let items = try store.list()
        #expect(items.count == 1)
        #expect(items[0].state == .failed)
        #expect(items[0].meta.error?.stage == .recording)
        #expect(items[0].meta.error?.reason == .deviceUnavailable)
        let detail = try #require(items[0].meta.error?.detail)
        #expect(detail.contains("soundcore Life Q30"))
        #expect(detail.contains("10"))  // the rebuilds it cost, for the log
    }

    /// The other side of the same call: with no rebuild behind it there is no evidence
    /// the device is at fault, so the failure keeps the name that claims less.
    @Test("a dead capture on an engine that never needed rebuilding stays empty_output")
    func deadCaptureWithoutRestartsStaysEmptyOutput() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 0
        recorder.captureFrames = 0
        recorder.captureEnergies = []
        recorder.captureRestarts = 0
        recorder.captureDeviceName = "MacBook Pro Microphone"
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(try store.list()[0].meta.error?.reason == .emptyOutput)
    }

    /// What the whole policy is for. The rebuilds are not a failure in themselves — a
    /// capture that took three of them and then recorded speech is an ordinary recording.
    @Test("a capture that recovered after rebuilds is queued like any other")
    func recoveredCaptureIsAccepted() async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.captureDuration = 8.0
        recorder.captureRestarts = 3
        recorder.captureDeviceName = "soundcore Life Q30"
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(try store.list()[0].state == .queued)
    }

    @Test("a dead capture never hands off to the transcription lane")
    func deadCaptureDoesNotQueue() async throws {
        defer { cleanup() }
        // There is no audio to transcribe: the failure is terminal at the recording
        // stage, and `mlx_whisper` hallucinates on the silence it would be handed.
        let coordinator = makeCoordinator()
        var queued: [String] = []
        coordinator.onQueued = { queued.append($0) }
        recorder.captureDuration = 0
        recorder.captureFrames = 0
        recorder.captureEnergies = []
        coordinator.start()
        await coordinator.stop(mode: .braindump)

        #expect(queued.isEmpty)
        #expect(try store.list()[0].state == .failed)
    }

    // MARK: - A recording-stage death reports its mode (#57)

    /// The signal the app turns into a sound for a dead dictation. The coordinator does
    /// not play anything — AppKit stays out of this target — it names the death and its
    /// mode, and the app decides. A dead capture is one of the two ways a recording dies
    /// before it ever reaches a lane.
    @Test("a dead capture reports the recording-stage failure with the item's mode", arguments: ItemMode.allCases)
    func deadCaptureReportsMode(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var failed: [ItemMode] = []
        coordinator.onRecordingFailed = { failed.append($0) }
        recorder.captureDuration = 0
        recorder.captureFrames = 0
        recorder.captureEnergies = []
        coordinator.start()
        await coordinator.stop(mode: mode)

        #expect(failed == [mode])
    }

    /// The other death: audio arrived and cleared the guard, but the encode failed. From
    /// the user's chair it is the same event as the dead capture — nothing landed — so it
    /// reports identically, carrying the mode.
    @Test("an encode failure reports the recording-stage failure with the item's mode", arguments: ItemMode.allCases)
    func encodeFailureReportsMode(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator(encoder: StubEncoder(shouldFail: true))
        var failed: [ItemMode] = []
        coordinator.onRecordingFailed = { failed.append($0) }
        coordinator.start()
        await coordinator.stop(mode: mode)

        #expect(failed == [mode])
    }

    /// The rule the sound already documents: a discard leaves no item, so nothing is
    /// owed. A too-short tap and a silent room both discard, in either mode, and neither
    /// reports a failure — the coordinator only reports the deaths that leave a `failed`
    /// item behind.
    @Test("a discarded recording reports no failure, in either mode", arguments: ItemMode.allCases)
    func discardReportsNoFailure(mode: ItemMode) async throws {
        defer { cleanup() }
        var failed: [ItemMode] = []

        let tooShort = makeCoordinator()
        tooShort.onRecordingFailed = { failed.append($0) }
        recorder.captureDuration = 0.1
        tooShort.start()
        await tooShort.stop(mode: mode)

        let silent = makeCoordinator()
        silent.onRecordingFailed = { failed.append($0) }
        recorder.captureDuration = 8.0
        recorder.captureEnergies = Array(repeating: 0.0004, count: 400)
        silent.start()
        await silent.stop(mode: mode)

        #expect(failed.isEmpty)
    }

    /// The graceful-quit sweep discards an in-progress recording with no item left
    /// behind, so it owes no sound either — the same rule, on the quit path.
    @Test("the quit-sweep discard reports no failure, in either mode", arguments: ItemMode.allCases)
    func quitSweepReportsNoFailure(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var failed: [ItemMode] = []
        coordinator.onRecordingFailed = { failed.append($0) }
        recorder.captureDuration = 8.0
        coordinator.start()
        coordinator.discardIfRecording()

        #expect(failed.isEmpty)
        #expect(try store.list().isEmpty)
    }

    /// The happy path reports no failure: an accepted recording lands `queued` and its
    /// signal is `onQueued`, not this.
    @Test("an accepted recording reports no failure, in either mode", arguments: ItemMode.allCases)
    func acceptReportsNoFailure(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        var failed: [ItemMode] = []
        coordinator.onRecordingFailed = { failed.append($0) }
        recorder.captureDuration = 8.0
        coordinator.start()
        await coordinator.stop(mode: mode)

        #expect(failed.isEmpty)
        #expect(try store.list()[0].state == .queued)
    }

    /// A refused recording stays silent too (#45, #57): nothing was captured and the
    /// degraded banner already says why, so no item is left behind and no failure is
    /// reported. Pinned rather than left to construction — the issue asked for this to be
    /// decided out loud.
    @Test("an unusable microphone refuses without reporting a failure", arguments: ItemMode.allCases)
    func refusalReportsNoFailure(mode: ItemMode) async throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        microphone.state = .silenced
        var failed: [ItemMode] = []
        coordinator.onRecordingFailed = { failed.append($0) }
        coordinator.start()
        await coordinator.stop(mode: mode)  // nothing to stop; the start was refused

        #expect(failed.isEmpty)
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
        #expect(!coordinator.isCapturing)
        #expect(try store.list().isEmpty)
        #expect(reported != nil)
    }

    /// The failure the mic can raise used to terminate the process (#55). Now that it is
    /// an error, the gesture after it has to be an ordinary recording: a failed start
    /// leaves nothing behind that could wedge the hotkey.
    @Test("a failed start does not wedge the next recording")
    func micStartFailureLeavesTheHotkeyWorking() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        recorder.throwOnStart = true
        coordinator.start()

        recorder.throwOnStart = false
        coordinator.start()
        #expect(coordinator.isCapturing)
        #expect(recorder.startCount == 2)
        #expect(try store.list().count == 1)
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

        #expect(!coordinator.isCapturing)
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
        #expect(!coordinator.isCapturing)
    }

    /// The refusal is reported and nothing else: no modal, no state change to recover
    /// from, and the next press of the hotkey is accepted exactly as before.
    @Test("a refusal leaves the hotkey working: the next start records once the mic is back")
    func refusalDoesNotBlockTheHotkey() throws {
        defer { cleanup() }
        let coordinator = makeCoordinator()
        microphone.state = .silenced
        coordinator.start()
        #expect(!coordinator.isCapturing)

        microphone.state = .usable
        coordinator.start()

        #expect(coordinator.isCapturing)
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

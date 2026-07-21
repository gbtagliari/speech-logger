import Foundation

/// What a finished recording produced: the temp wav plus the two measurements the
/// dual guard needs. The wav is deleted once the mp3 exists.
public struct RecordingCapture: Sendable, Equatable {
    /// The native wav streamed to a temp file during capture.
    public let wav: URL
    /// Recording length in seconds.
    public let duration: TimeInterval
    /// Peak sample amplitude seen (0…1), for the energy floor.
    public let peak: Float

    public init(wav: URL, duration: TimeInterval, peak: Float) {
        self.wav = wav
        self.duration = duration
        self.peak = peak
    }
}

/// The microphone capture seam. The concrete implementation (AVAudioEngine) lives
/// in the app target; the coordinator depends only on this so its orchestration is
/// testable without hardware.
@MainActor public protocol AudioRecording: AnyObject {
    /// Begin streaming the mic to a temp wav. Throws if capture cannot start (e.g.
    /// microphone access denied).
    func start() throws
    /// Stop capture and return the recorded file plus its measurements.
    func stop() -> RecordingCapture
}

/// The wav → mp3 encode seam (concrete impl: `AudioEncoder` over `ffmpeg`).
public protocol AudioEncoding: Sendable {
    func encode(wav: URL, to mp3: URL) async throws
}

/// Orchestrates one recording gesture end to end: hotkey toggle → capture → dual
/// guard → encode → item lands `queued` (ADR-0006). Recording is exclusive, and the
/// toggle's behavior depends only on whether the mic is currently live: a queued or
/// processing item never holds up the next recording.
///
/// One thing does refuse a new recording, and only one: a microphone the device itself
/// reports as unusable (#45). Nothing else — a missing binary, a denied notification, a
/// full pipeline — ever costs a thought.
///
/// Foundation-only and `@MainActor`, with the hardware seams injected, so the whole
/// flow is unit-testable against a real store on a temp directory.
@MainActor public final class RecordingCoordinator {
    private let store: ItemStore
    private let recorder: any AudioRecording
    private let encoder: any AudioEncoding
    private let guardCheck: RecordingGuard
    /// The device query, run at the start of every recording. Injected so an unusable
    /// microphone is testable without one, and so this target stays free of AVFoundation.
    private let microphone: @MainActor () -> MicrophoneState

    /// The mic is live. Drives the `recording` glyph and the running clock.
    public private(set) var isRecording = false
    /// The item currently being recorded, if any.
    private var currentItemID: String?

    /// Called after any state-affecting step, so the menubar can recompute its glyph.
    public var onStateChange: (@MainActor () -> Void)?
    /// Called with the item id the instant it lands `queued`, so the transcription
    /// lane can pick it up (ADR-0006). The hero handoff from recording to the pipeline.
    public var onQueued: (@MainActor (String) -> Void)?
    /// Called when the mic fails to start (e.g. access denied), so the app can
    /// surface it. The item is discarded; the app stays idle.
    public var onRecorderStartFailed: (@MainActor (Error) -> Void)?
    /// Called when an unusable microphone refuses a recording, with the device problem
    /// that refused it. Nothing was created and nothing was captured; the app stays
    /// idle and the hotkey keeps working.
    public var onRecordingRefused: (@MainActor (MicrophoneState) -> Void)?

    public init(
        store: ItemStore,
        recorder: any AudioRecording,
        encoder: any AudioEncoding,
        guardCheck: RecordingGuard = RecordingGuard(),
        // No default: this is a hardware seam like the recorder and the encoder, and a
        // caller that forgot it would silently record with the check disabled.
        microphone: @escaping @MainActor () -> MicrophoneState
    ) {
        self.store = store
        self.recorder = recorder
        self.encoder = encoder
        self.guardCheck = guardCheck
        self.microphone = microphone
    }

    /// The hotkey. Start if idle, stop if recording — nothing else. Never blocked: a
    /// press always reaches here, and the only thing that can turn it down is an
    /// unusable microphone (see `start`).
    public func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    /// Start a recording: check the microphone, create the item at `recording`, open
    /// the mic. A second call while already recording is a no-op (exclusive recording).
    ///
    /// The device is queried here and not only at panel-open, because mute state
    /// changes in between and the start of a recording is the only instant that
    /// matters. An unusable device refuses: capturing while knowing nothing will arrive
    /// is manufacturing the loss on purpose, and the refusal costs a moment where the
    /// capture would cost a whole braindump.
    public func start() {
        guard !isRecording else { return }
        let microphoneState = microphone()
        guard microphoneState.isUsable else {
            onRecordingRefused?(microphoneState)
            return
        }
        let item: Item
        do {
            item = try store.create()
        } catch {
            onRecorderStartFailed?(error)
            return
        }
        do {
            try recorder.start()
        } catch {
            try? store.discard(item.id)  // no capture happened; nothing to keep
            onRecorderStartFailed?(error)
            onStateChange?()
            return
        }
        currentItemID = item.id
        isRecording = true
        onStateChange?()
    }

    /// Stop the current recording and run it through the guard and encoder. A call
    /// while not recording is a no-op.
    public func stop() async {
        guard isRecording, let id = currentItemID else { return }
        isRecording = false
        currentItemID = nil
        let capture = recorder.stop()
        onStateChange?()  // mic is off; the glyph drops out of `recording`
        await process(id: id, capture: capture)
    }

    /// Discard an in-progress recording silently (graceful quit, ADR-0006):
    /// stop the mic, throw the capture away, and hard-remove the item. A recording has
    /// nothing to resume, so it leaves no `cancelled` off-ramp and no Trash entry —
    /// just as a too-short tap does. A call while not recording is a no-op.
    public func discardIfRecording() {
        guard isRecording, let id = currentItemID else { return }
        isRecording = false
        currentItemID = nil
        let capture = recorder.stop()
        try? FileManager.default.removeItem(at: capture.wav)
        try? store.discard(id)
        onStateChange?()
    }

    /// Apply the dual guard, then encode-and-queue, discard, or fail. The temp wav
    /// is always removed on the way out — the mp3 is the retained artifact.
    private func process(id: String, capture: RecordingCapture) async {
        defer { try? FileManager.default.removeItem(at: capture.wav) }

        switch guardCheck.evaluate(duration: capture.duration, peak: capture.peak) {
        case .discardTooShort:
            // An accidental tap: it never becomes a visible log item.
            try? store.discard(id)
        case .rejectSilent:
            // Long enough but silent: fail cleanly rather than hallucinate.
            _ = try? store.fail(id, stage: .recording, reason: .noSpeech, detail: "silent recording")
        case .accept:
            do {
                let mp3 = try store.contentURL(of: ItemFile.audio, for: id)
                try await encoder.encode(wav: capture.wav, to: mp3)
                _ = try store.markQueued(id, duration: capture.duration)
                onQueued?(id)  // hand the item to the serial transcription lane
            } catch {
                _ = try? store.fail(
                    id, stage: .recording, reason: .cliError, detail: "encode failed: \(error)")
            }
        }
        onStateChange?()
    }
}

import Foundation

/// What a finished recording produced: the temp wav plus the two measurements the
/// dual guard needs. The wav is deleted once the mp3 exists (SPEC "The pipeline").
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
/// guard → encode → item lands `queued` (ADR-0006, SPEC "The pipeline"). Recording
/// is exclusive and the hotkey never refuses a new one — the toggle's behavior
/// depends only on whether the mic is currently live.
///
/// Foundation-only and `@MainActor`, with the hardware seams injected, so the whole
/// flow is unit-testable against a real store on a temp directory.
@MainActor public final class RecordingCoordinator {
    private let store: ItemStore
    private let recorder: any AudioRecording
    private let encoder: any AudioEncoding
    private let guardCheck: RecordingGuard

    /// The mic is live. Drives the `recording` glyph and the running clock.
    public private(set) var isRecording = false
    /// The item currently being recorded, if any.
    private var currentItemID: String?

    /// Called after any state-affecting step, so the menubar can recompute its glyph.
    public var onStateChange: (@MainActor () -> Void)?
    /// Called when the mic fails to start (e.g. access denied), so the app can
    /// surface it. The item is discarded; the app stays idle.
    public var onRecorderStartFailed: (@MainActor (Error) -> Void)?

    public init(
        store: ItemStore,
        recorder: any AudioRecording,
        encoder: any AudioEncoding,
        guardCheck: RecordingGuard = RecordingGuard()
    ) {
        self.store = store
        self.recorder = recorder
        self.encoder = encoder
        self.guardCheck = guardCheck
    }

    /// The hotkey. Start if idle, stop if recording — nothing else. Always accepted.
    public func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    /// Start a recording: create the item at `recording` and open the mic. A second
    /// call while already recording is a no-op (exclusive recording).
    public func start() {
        guard !isRecording else { return }
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

    /// Apply the dual guard, then encode-and-queue, discard, or fail. The temp wav
    /// is always removed on the way out — the mp3 is the retained artifact.
    private func process(id: String, capture: RecordingCapture) async {
        defer { try? FileManager.default.removeItem(at: capture.wav) }

        switch guardCheck.evaluate(duration: capture.duration, peak: capture.peak) {
        case .discardTooShort:
            // An accidental tap: it never becomes a visible log item (story 32).
            try? store.discard(id)
        case .rejectSilent:
            // Long enough but silent: fail cleanly rather than hallucinate (story 33).
            _ = try? store.fail(id, stage: .recording, reason: .noSpeech, detail: "silent recording")
        case .accept:
            do {
                let mp3 = try store.contentURL(of: ItemFile.audio, for: id)
                try await encoder.encode(wav: capture.wav, to: mp3)
                _ = try store.markQueued(id, duration: capture.duration)
            } catch {
                _ = try? store.fail(
                    id, stage: .recording, reason: .cliError, detail: "encode failed: \(error)")
            }
        }
        onStateChange?()
    }
}

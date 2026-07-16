import Foundation

/// The single serial FIFO transcription lane (ADR-0006). Items that finished
/// recording wait in `queued`; this lane picks them up one at a time, runs
/// `mlx_whisper`, and writes the raw transcript — `queued` → `transcribing` →
/// transcript file on disk. Serializing costs ~20% over running two at once and
/// removes all GPU contention, so it is the deliberate model, not a limitation
/// (`docs/research/mlx-whisper-shell-out-contract.md`).
///
/// An actor with one drain loop: `enqueue` is fire-and-forget (the recording
/// coordinator calls it the instant an item lands `queued` and must not block on a
/// transcription), and a lone `drainTask` guarantees exactly one item transcribes
/// at a time regardless of how fast items arrive. Foundation-only with the
/// `mlx_whisper` seam injected, so the whole lane is unit-testable without the binary.
public actor TranscriptionLane {
    private let store: ItemStore
    private let transcriber: any Transcribing
    /// Fired after every state-affecting step, so the menubar can recompute its glyph.
    private let onStateChange: (@Sendable () -> Void)?
    /// The handoff seam: fired with the item id once its transcript is written. The
    /// item is still `transcribing` — organization (a later ticket) is the consumer
    /// that advances it to `organizing`. Absent that consumer, the item rests here.
    private let onTranscribed: (@Sendable (String) -> Void)?

    /// The FIFO backlog. Only touched on the actor, so no lock is needed.
    private var queue: [String] = []
    /// The lone consumer. Non-nil exactly while the lane is draining; `waitUntilIdle`
    /// awaits it. One task drains the whole backlog, so a burst of `enqueue`s never
    /// spawns a second lane.
    private var drainTask: Task<Void, Never>?

    public init(
        store: ItemStore,
        transcriber: any Transcribing,
        onStateChange: (@Sendable () -> Void)? = nil,
        onTranscribed: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.transcriber = transcriber
        self.onStateChange = onStateChange
        self.onTranscribed = onTranscribed
    }

    /// Add an item to the back of the lane. Returns immediately; the transcription
    /// runs on the drain task. Starting the drain only when idle keeps the lane serial.
    public func enqueue(_ id: String) {
        queue.append(id)
        if drainTask == nil {
            drainTask = Task { await self.drain() }
        }
    }

    /// Await the lane going idle (the current backlog fully processed). Used by tests
    /// and, later, by graceful quit.
    public func waitUntilIdle() async {
        await drainTask?.value
    }

    /// Process the backlog one item at a time until empty. Clearing `drainTask`
    /// happens with no suspension after the queue is observed empty, so a concurrent
    /// `enqueue` cannot be lost between the check and the clear (actor non-reentrancy).
    private func drain() async {
        while let id = next() {
            await process(id)
        }
        drainTask = nil
    }

    private func next() -> String? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func process(_ id: String) async {
        // Only a still-`queued` item runs. One that was cancelled/failed/deleted
        // between enqueue and pickup is skipped, never revived.
        guard (try? store.meta(for: id))?.state == .queued else { return }
        do {
            _ = try store.markTranscribing(id)
            onStateChange?()
            let audio = try store.contentURL(of: ItemFile.audio, for: id)
            let transcript = try store.contentURL(of: ItemFile.transcript, for: id)
            try await transcriber.transcribe(audio: audio, to: transcript)
            // Success: the transcript is on disk and the item is `transcribing`.
            // Hand off to organization (a later ticket) rather than advancing here.
            onTranscribed?(id)
        } catch let error as TranscriptionError {
            fail(id, error)
            onStateChange?()
        } catch {
            // A store error mid-transition (e.g. the item directory vanished).
            _ = try? store.fail(id, stage: .transcription, reason: .cliError, detail: "\(error)")
            onStateChange?()
        }
    }

    /// Record a transcription failure with the reason its `TranscriptionError` maps to
    /// (CONTEXT.md failure vocabulary). Retryable — it reuses the same lane.
    private func fail(_ id: String, _ error: TranscriptionError) {
        let reason: FailureReason
        let detail: String
        switch error {
        case .emptyOutput(let stderr):
            reason = .emptyOutput
            // The stderr tail says which of the four empty-output causes fired; fall
            // back to a plain note when it happens to be empty.
            detail = stderr.isEmpty ? "mlx_whisper produced no transcript" : stderr
        case .launchFailed(let message):
            reason = .missingBinary
            detail = message
        case .io(let message):
            reason = .cliError
            detail = message
        }
        _ = try? store.fail(id, stage: .transcription, reason: reason, detail: detail)
    }
}

import Foundation

/// The single serial FIFO transcription lane (ADR-0006). Items that finished
/// recording wait in `queued`; this lane picks them up one at a time, runs
/// `mlx_whisper`, and writes the raw transcript — `queued` → `transcribing` →
/// transcript file on disk. Both modes share it, and it is where their paths fork:
/// a braindump hands off to organization, a dictation rests at `transcribed` (#41). Serializing costs ~20% over running two at once and
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
    /// item is still `transcribing` — organization is the consumer that advances it to
    /// `organizing`. Absent that consumer, the item rests here.
    ///
    /// **Braindumps only** (#41). A dictation has no organization stage, so the lane
    /// advances it to `transcribed` itself and never fires this.
    private let onTranscribed: (@Sendable (String) -> Void)?
    /// Dictation's delivery seam (#42): fired with the finished **transcript text**
    /// once the item rests at `transcribed`. The lane owns *when* a dictation is
    /// deliverable; the app target owns *how* (the clipboard write is AppKit, and this
    /// module is Foundation-only). Dictations only — a braindump is collected from the
    /// panel, never pushed.
    private let onDictationReady: (@Sendable (_ transcript: String) -> Void)?

    /// The FIFO backlog. Only touched on the actor, so no lock is needed.
    private var queue: [String] = []
    /// The lone consumer. Non-nil exactly while the lane is draining; `waitUntilIdle`
    /// awaits it. One task drains the whole backlog, so a burst of `enqueue`s never
    /// spawns a second lane.
    private var drainTask: Task<Void, Never>?
    /// The item currently transcribing, and the task running it. The drain runs each
    /// item in its own child task so `cancel`/`shutdown` can kill just the in-flight
    /// transcription (terminating `mlx_whisper`) without tearing down the whole lane.
    private var currentID: String?
    private var currentTask: Task<Void, Never>?

    public init(
        store: ItemStore,
        transcriber: any Transcribing,
        onStateChange: (@Sendable () -> Void)? = nil,
        onTranscribed: (@Sendable (String) -> Void)? = nil,
        onDictationReady: (@Sendable (_ transcript: String) -> Void)? = nil
    ) {
        self.store = store
        self.transcriber = transcriber
        self.onStateChange = onStateChange
        self.onTranscribed = onTranscribed
        self.onDictationReady = onDictationReady
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
    /// and by graceful quit.
    public func waitUntilIdle() async {
        await drainTask?.value
    }

    /// Stop one item (the manual "stop processing" control). A still-`queued` item is
    /// dropped from the backlog and marked `cancelled` directly (no process to kill).
    /// The in-flight `transcribing` item is stopped by cancelling its task,
    /// which terminates `mlx_whisper`; `process` then records the `cancelled` state.
    /// An id this lane does not own (already organizing, or gone) is a no-op — the
    /// controller also asks the organization lane, and the owner acts.
    public func cancel(_ id: String) {
        if id == currentID {
            currentTask?.cancel()
            return
        }
        guard queue.contains(id) else { return }
        queue.removeAll { $0 == id }
        _ = try? store.cancel(id, stage: .transcription)
        onStateChange?()
    }

    /// Graceful quit: kill the in-flight transcription (terminates `mlx_whisper`) and
    /// drop the backlog. Never blocks — it sends the terminate signal and returns,
    /// leaving the process to die on its own (ADR-0006, "quit never blocks"). The
    /// controller has already marked the affected items `cancelled`.
    public func shutdown() {
        currentTask?.cancel()
        queue.removeAll()
    }

    /// Process the backlog one item at a time until empty. Each item runs in its own
    /// child task (recorded as `currentTask`) so a per-item `cancel` can kill just it;
    /// the drain awaits that task before taking the next id, preserving serial order.
    /// Clearing `drainTask` happens with no suspension after the queue is observed
    /// empty, so a concurrent `enqueue` cannot be lost between the check and the clear
    /// (actor non-reentrancy).
    private func drain() async {
        while let id = next() {
            currentID = id
            let task = Task { await self.process(id) }
            currentTask = task
            await task.value
            currentID = nil
            currentTask = nil
        }
        drainTask = nil
    }

    private func next() -> String? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func process(_ id: String) async {
        // Only a still-`queued` item runs. One that was cancelled/failed/deleted
        // between enqueue and pickup is skipped, never revived. The mode is read here,
        // at pickup, and it cannot change under a running item.
        guard let queued = try? store.meta(for: id), queued.state == .queued else { return }
        do {
            _ = try store.markTranscribing(id)
            onStateChange?()
            let audio = try store.contentURL(of: ItemFile.audio, for: id)
            let transcript = try store.contentURL(of: ItemFile.transcript, for: id)
            try await transcriber.transcribe(audio: audio, to: transcript)
            // Success: the transcript is on disk and the item is `transcribing`. Where it
            // goes from here is the whole structural difference between the modes, and
            // this is the fork (#41): a dictation is *done* — the transcript is its
            // output — so it advances to its own terminal and rests. A braindump hands
            // off to organization instead of advancing, and the consumer moves it on.
            //
            // Not firing `onTranscribed` for a dictation is what makes "zero LLM
            // invocations" structural rather than a promise: this is the only seam that
            // reaches the organization lane, so an unfired handoff cannot run a pass.
            switch queued.mode {
            case .dictation:
                _ = try store.markTranscribed(id)
                onStateChange?()
                deliver(id)
            case .braindump:
                onTranscribed?(id)
            }
        } catch {
            // A cancelled task (stop / quit) killed `mlx_whisper`, surfacing as a
            // transcription/store error. Record `cancelled`, not `failed` — unless
            // something already moved the item terminal (quit marks it synchronously),
            // which we must not clobber.
            if Task.isCancelled {
                if let meta = try? store.meta(for: id), !meta.state.isTerminal {
                    _ = try? store.cancel(id, stage: .transcription)
                }
            } else if let error = error as? TranscriptionError {
                fail(id, error)
            } else {
                // A store error mid-transition (e.g. the item directory vanished).
                _ = try? store.fail(id, stage: .transcription, reason: .cliError, detail: "\(error)")
            }
            onStateChange?()
        }
    }

    /// Hand a finished dictation's transcript to its delivery (#42) — today the
    /// clipboard, every time and never restored, which is the whole of the mode's
    /// output until the paste lands on top of it.
    ///
    /// Read *after* the state flip and tolerant of failure: the item is `transcribed`
    /// either way, so an unreadable transcript costs the clipboard write, not the
    /// item. There is nothing to fail it with — the transcript is on disk, which is
    /// what `transcribed` claims.
    private func deliver(_ id: String) {
        guard let onDictationReady else { return }
        guard let data = try? store.read(file: ItemFile.transcript, for: id) else { return }
        onDictationReady(String(decoding: data, as: UTF8.self))
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

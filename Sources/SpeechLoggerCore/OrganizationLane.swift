import Foundation

/// The unbounded parallel organization lane (ADR-0006). The serial transcription
/// lane drip-feeds it: the instant an item's transcript is written, `organize` is
/// called and the two `claude` passes run — `transcribing` → `organizing` →
/// `organized`. Organization is network-bound and parallelises cleanly (unlike the
/// GPU-bound transcription), so each item gets its own task and many run at once
/// (`docs/research/claude-cli-shell-out-contract.md`).
///
/// An actor guarding a task-per-item registry, so `organize` is fire-and-forget and
/// never serialises two items. Foundation-only with the `claude` seam injected, so
/// the whole lane is unit-testable without the binary.
public actor OrganizationLane {
    private let store: ItemStore
    private let organizer: any Organizing
    /// Fired after every state-affecting step, so the menubar can recompute its glyph.
    private let onStateChange: (@Sendable () -> Void)?
    /// Fired with the item id once it reaches `organized`, so the app can raise the
    /// ready notification (a later ticket). Absent that consumer, the item rests done.
    private let onOrganized: (@Sendable (String) -> Void)?

    /// One in-flight task per item, so a duplicate `organize` for an id already
    /// running is ignored and each item is cleared from the registry when it settles.
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        store: ItemStore,
        organizer: any Organizing,
        onStateChange: (@Sendable () -> Void)? = nil,
        onOrganized: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.organizer = organizer
        self.onStateChange = onStateChange
        self.onOrganized = onOrganized
    }

    /// Start organizing an item. Returns immediately; the two passes run on a
    /// per-item task. A second call for an id already in flight is a no-op.
    ///
    /// `from` is the resume stage (default `.pass1`, a fresh organization). A retry at
    /// `.pass2` skips annotate and rewrites from the retained `pass1.txt`, reusing the
    /// pivot rather than re-annotating (#22).
    public func organize(_ id: String, from stage: Stage = .pass1) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task {
            await self.process(id, from: stage)
            self.tasks[id] = nil
        }
    }

    /// Stop one organizing item (the manual "stop processing" control):
    /// cancel its task, which terminates the in-flight `claude` pass; `process` then
    /// records `cancelled` at whichever pass was interrupted. An id this lane is not
    /// running is a no-op.
    public func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Graceful quit: cancel every in-flight item, terminating their `claude` passes.
    /// Never blocks — the cancellation handlers send SIGTERM and return; the controller
    /// has already marked the items `cancelled` (ADR-0006, "quit never blocks").
    public func shutdown() {
        for task in tasks.values { task.cancel() }
    }

    /// Await every in-flight item settling. Used by tests and graceful quit.
    public func waitUntilIdle() async {
        // Copy the tasks into an array first: awaiting each one suspends the actor,
        // during which a finishing task clears its own `tasks[id]` entry. Iterating
        // the live dictionary view across that mutation is undefined; the array is an
        // independent snapshot of the current backlog, immune to it.
        let running = Array(tasks.values)
        for task in running { await task.value }
    }

    private func process(_ id: String, from stage: Stage) async {
        // Only a still-`transcribing` item runs — that is the handoff state both the
        // transcription lane (fresh) and a retry (`resumeForOrganizing`) leave it in.
        // One cancelled/failed/deleted between handoff and pickup is skipped, never
        // revived.
        guard (try? store.meta(for: id))?.state == .transcribing else { return }
        do {
            _ = try store.markOrganizing(id)
            onStateChange?()

            let pass1: String
            if stage == .pass2 {
                // Resume at pass 2: reuse the retained pivot, skip annotate (#22).
                pass1 = try readPass1(id)
            } else {
                // Pass 1: annotate, and retain the pivot immediately. Persisting it
                // before pass 2 means a pass-2 failure still leaves `pass1.txt` on
                // disk, which makes the two-pass contract auditable end to end
                // (ADR-0001) and lets a pass-2 retry reuse it.
                let transcript = try readTranscript(id)
                pass1 = try await organizer.annotate(transcript)
                try store.write(Data(pass1.utf8), to: ItemFile.pass1, for: id)
            }

            // Pass 2: rewrite. `markOrganized` writes the final text, *then* flips the
            // state, so the invariant "final text present only in `organized`" holds.
            let final = try await organizer.rewrite(pass1)
            _ = try store.markOrganized(id, finalText: final)
            onStateChange?()
            onOrganized?(id)
        } catch {
            settle(id, error: error, resumeStage: stage)
            onStateChange?()
        }
    }

    /// Record how an interrupted organization ended. A cancelled task (stop / quit)
    /// killed `claude` mid-pass: mark `cancelled` at the pass that was running, unless
    /// something already moved the item terminal (quit marks it synchronously). Any
    /// other error is a genuine `failed`.
    private func settle(_ id: String, error: any Error, resumeStage: Stage) {
        if Task.isCancelled {
            guard let meta = try? store.meta(for: id), !meta.state.isTerminal else { return }
            _ = try? store.cancel(id, stage: interruptedStage(error, resumeStage: resumeStage))
        } else if let error = error as? OrganizationError {
            fail(id, error)
        } else {
            // A store failure mid-transition (e.g. the item directory vanished, or a
            // required artifact is missing). Record it at the resume stage.
            _ = try? store.fail(id, stage: resumeStage, reason: .cliError, detail: "\(error)")
        }
    }

    /// The pass a cancellation interrupted: an `OrganizationError` carries its own
    /// stage (`annotate` throws pass1, `rewrite` throws pass2); otherwise fall back to
    /// the resume stage this run started from.
    private func interruptedStage(_ error: any Error, resumeStage: Stage) -> Stage {
        if case .failed(let stage, _, _)? = error as? OrganizationError { return stage }
        return resumeStage
    }

    /// Read the raw transcript the transcription lane wrote. Its absence is a store
    /// precondition failure (there is nothing to organize), surfaced as a pass-1 error.
    private func readTranscript(_ id: String) throws(StoreError) -> String {
        guard let data = try store.read(file: ItemFile.transcript, for: id) else {
            throw StoreError.io("transcript missing for \(id)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Read the retained pass-1 pivot for a pass-2 resume. Its absence means the retry
    /// was routed to pass 2 without a pivot on disk — a precondition failure surfaced
    /// as a pass-2 error, never a silent re-annotate.
    private func readPass1(_ id: String) throws(StoreError) -> String {
        guard let data = try store.read(file: ItemFile.pass1, for: id) else {
            throw StoreError.io("pass1 pivot missing for \(id)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Record an organization failure at the stage its `OrganizationError` carries.
    /// Retryable — it reuses the same parallel lane.
    private func fail(_ id: String, _ error: OrganizationError) {
        guard case .failed(let stage, let reason, let detail) = error else { return }
        _ = try? store.fail(id, stage: stage, reason: reason, detail: detail)
    }
}

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
    public func organize(_ id: String) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task {
            await self.process(id)
            self.tasks[id] = nil
        }
    }

    /// Await every in-flight item settling. Used by tests and, later, graceful quit.
    public func waitUntilIdle() async {
        // Copy the tasks into an array first: awaiting each one suspends the actor,
        // during which a finishing task clears its own `tasks[id]` entry. Iterating
        // the live dictionary view across that mutation is undefined; the array is an
        // independent snapshot of the current backlog, immune to it.
        let running = Array(tasks.values)
        for task in running { await task.value }
    }

    private func process(_ id: String) async {
        // Only a still-`transcribing` item runs — that is the handoff state the
        // transcription lane leaves it in. One cancelled/failed/deleted between
        // handoff and pickup is skipped, never revived.
        guard (try? store.meta(for: id))?.state == .transcribing else { return }
        do {
            _ = try store.markOrganizing(id)
            onStateChange?()

            let transcript = try readTranscript(id)

            // Pass 1: annotate, and retain the pivot immediately. Persisting it before
            // pass 2 means a pass-2 failure still leaves `pass1.txt` on disk, which is
            // what makes the two-pass contract auditable end to end (ADR-0001).
            let pass1 = try await organizer.annotate(transcript)
            try store.write(Data(pass1.utf8), to: ItemFile.pass1, for: id)

            // Pass 2: rewrite. `markOrganized` writes the final text, *then* flips the
            // state, so the invariant "final text present only in `organized`" holds.
            let final = try await organizer.rewrite(pass1)
            _ = try store.markOrganized(id, finalText: final)
            onStateChange?()
            onOrganized?(id)
        } catch let error as OrganizationError {
            fail(id, error)
            onStateChange?()
        } catch {
            // A store failure mid-transition (e.g. the item directory vanished, or the
            // transcript is missing). Record it at pass 1, the entry of organization —
            // consistent with `ItemStore.recoveryStage`, which also maps an `organizing`
            // death to `pass1` rather than pinpointing which pass's store write failed.
            _ = try? store.fail(id, stage: .pass1, reason: .cliError, detail: "\(error)")
            onStateChange?()
        }
    }

    /// Read the raw transcript the transcription lane wrote. Its absence is a store
    /// precondition failure (there is nothing to organize), surfaced as a pass-1 error.
    private func readTranscript(_ id: String) throws(StoreError) -> String {
        guard let data = try store.read(file: ItemFile.transcript, for: id) else {
            throw StoreError.io("transcript missing for \(id)")
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

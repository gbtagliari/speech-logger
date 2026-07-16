import Foundation
import Testing

@testable import SpeechLoggerCore

/// The unbounded parallel lane (ADR-0006) and the two-pass state machine (ADR-0001):
/// a transcribed item goes `transcribing` → `organizing` → `organized`, the annotated
/// pass-1 pivot is retained (even when pass 2 fails), the final text is pass-2 output
/// only, and items organize concurrently. The `claude` seam is faked so these run
/// without the binary; a guarded end-to-end test drives real passes through the lane.
struct OrganizationLaneTests {
    // MARK: - Happy path

    @Test("a transcribed item goes organizing -> organized, retaining pass1.txt and the final text")
    func organizesATranscribedItem() async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "olha só isso aí tipo funciona")
        let collector = Collector()
        let lane = OrganizationLane(
            store: store,
            organizer: FakeOrganizer(),
            onStateChange: { collector.bumpState() },
            onOrganized: { collector.addOrganized($0) })

        await lane.organize(id)
        await lane.waitUntilIdle()

        #expect(try store.meta(for: id).state == .organized)
        // The annotated pivot is retained (auditable two-pass trail).
        let pass1 = try #require(try store.read(file: ItemFile.pass1, for: id))
        #expect(String(decoding: pass1, as: UTF8.self) == FakeOrganizer.annotated("olha só isso aí tipo funciona"))
        // The copyable final text is pass-2 output, present only in `organized`.
        #expect(try store.finalText(for: id) == FakeOrganizer.rewritten(FakeOrganizer.annotated("olha só isso aí tipo funciona")))
        // It handed off exactly once.
        #expect(collector.organized == [id])
    }

    @Test("the final text is pass-2 output only, and is absent before the item is organized")
    func finalTextIsPass2Only() async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "texto qualquer")
        // Before organization: no final text (the invariant holds at every prior state).
        #expect(try store.finalText(for: id) == nil)

        let lane = OrganizationLane(store: store, organizer: FakeOrganizer())
        await lane.organize(id)
        await lane.waitUntilIdle()

        let final = try #require(try store.finalText(for: id))
        let pivot = String(decoding: try #require(try store.read(file: ItemFile.pass1, for: id)), as: UTF8.self)
        // The final copyable text is pass 2's rewrite of the pivot, never the pivot itself.
        #expect(final == FakeOrganizer.rewritten(pivot))
        #expect(final != pivot)
        #expect(final.hasPrefix("REWRITTEN"))
    }

    // MARK: - Failure mapping

    @Test(
        "a pass failure marks the item failed at the right stage with the right reason",
        arguments: [
            (Stage.pass1, FailureReason.cliError),
            (Stage.pass1, FailureReason.emptyOutput),
            (Stage.pass2, FailureReason.cliError),
            (Stage.pass2, FailureReason.missingBinary),
        ])
    func mapsPassFailures(stage: Stage, reason: FailureReason) async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "algo")
        let collector = Collector()
        let lane = OrganizationLane(
            store: store,
            organizer: ThrowingOrganizer(
                error: .failed(stage: stage, reason: reason, detail: "boom")),
            onOrganized: { collector.addOrganized($0) })

        await lane.organize(id)
        await lane.waitUntilIdle()

        let meta = try store.meta(for: id)
        #expect(meta.state == .failed)
        #expect(meta.error?.stage == stage)
        #expect(meta.error?.reason == reason)
        // A failure never hands off as organized.
        #expect(collector.organized.isEmpty)
    }

    @Test("a pass-2 failure still leaves pass1.txt on disk — the pivot is retained for audit/retry")
    func pass2FailureRetainsPass1() async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "algo para anotar")
        // Pass 1 succeeds and is written; pass 2 throws.
        let lane = OrganizationLane(
            store: store,
            organizer: Pass2FailingOrganizer())

        await lane.organize(id)
        await lane.waitUntilIdle()

        #expect(try store.meta(for: id).state == .failed)
        #expect(try store.meta(for: id).error?.stage == .pass2)
        // The annotated pivot survived the pass-2 failure.
        let pass1 = try #require(try store.read(file: ItemFile.pass1, for: id))
        #expect(String(decoding: pass1, as: UTF8.self) == FakeOrganizer.annotated("algo para anotar"))
        // But there is no final text — the invariant holds on the failure path too.
        #expect(try store.finalText(for: id) == nil)
    }

    // MARK: - The transcribing guard

    @Test("an item that is not transcribing is skipped, never organized")
    func skipsANonTranscribingItem() async throws {
        let store = try makeStore()
        let item = try store.create()
        // Cancelled before the lane picks it up: nothing to organize.
        _ = try store.cancel(item.id, stage: .transcription)
        let organizer = CountingOrganizer()
        let lane = OrganizationLane(store: store, organizer: organizer)

        await lane.organize(item.id)
        await lane.waitUntilIdle()

        #expect(await organizer.calls == 0)  // never invoked claude
        #expect(try store.meta(for: item.id).state == .cancelled)  // left untouched
    }

    // MARK: - Unbounded parallel

    @Test("three items organize concurrently, not one at a time")
    func organizesInParallel() async throws {
        let store = try makeStore()
        let ids = try (0..<3).map { try transcribedItem(in: store, transcript: "item \($0)") }
        // A rendezvous of 3: each item's pass 1 blocks until all three have arrived,
        // so the barrier can only clear if the lane runs them in parallel. A serial
        // lane would deadlock here — which the timeout below turns into a clean failure
        // rather than a hang.
        let rendezvous = Rendezvous(expected: ids.count)
        let lane = OrganizationLane(store: store, organizer: RendezvousOrganizer(rendezvous: rendezvous))

        for id in ids { await lane.organize(id) }
        let finished = await withinTimeout(seconds: 5) { await lane.waitUntilIdle() }
        #expect(finished, "the lane did not run the items in parallel (barrier never cleared)")

        // All three reached `organized`.
        for id in ids { #expect(try store.meta(for: id).state == .organized) }
    }

    // MARK: - Cancellation (the manual "stop" and graceful quit)

    @Test(
        "stopping an organizing item marks it cancelled at the pass that was running",
        arguments: [Stage.pass1, Stage.pass2])
    func cancelOrganizingItem(blockOn: Stage) async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "algo")
        let lane = OrganizationLane(store: store, organizer: BlockingOrganizer(blockOn: blockOn))

        await lane.organize(id)
        try await waitUntil { (try? store.meta(for: id))?.state == .organizing }
        await lane.cancel(id)
        await lane.waitUntilIdle()

        let meta = try store.meta(for: id)
        #expect(meta.state == .cancelled)  // cancelled, never failed
        #expect(meta.stoppedAt?.stage == blockOn)
    }

    // MARK: - Retry resume (#22)

    @Test("resuming at pass2 reuses the retained pass1 pivot and never re-annotates")
    func resumeAtPass2ReusesPivot() async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "irrelevante para o pass2")
        // A prior attempt left the annotated pivot on disk.
        try store.write(Data("PIVOT".utf8), to: ItemFile.pass1, for: id)
        let organizer = RecordingOrganizer()
        let lane = OrganizationLane(store: store, organizer: organizer)

        await lane.organize(id, from: .pass2)
        await lane.waitUntilIdle()

        #expect(await organizer.annotateCalls == 0)  // pass 1 skipped
        #expect(await organizer.rewriteInputs == ["PIVOT"])  // rewrote the retained pivot
        #expect(try store.meta(for: id).state == .organized)
        #expect(try store.finalText(for: id) == FakeOrganizer.rewritten("PIVOT"))
    }

    @Test("a pass2 resume with no retained pivot fails at pass2, never silently re-annotating")
    func resumeAtPass2WithoutPivotFails() async throws {
        let store = try makeStore()
        let id = try transcribedItem(in: store, transcript: "tem transcrição mas não tem pivô")
        let organizer = RecordingOrganizer()
        let lane = OrganizationLane(store: store, organizer: organizer)

        await lane.organize(id, from: .pass2)
        await lane.waitUntilIdle()

        let meta = try store.meta(for: id)
        #expect(meta.state == .failed)
        #expect(meta.error?.stage == .pass2)
        #expect(await organizer.annotateCalls == 0)  // never fell back to re-annotating
    }

    // MARK: - End-to-end (real claude against a real sample transcript)

    @Test(
        "a real transcribed item organizes end-to-end through the lane",
        .enabled(if: AcceptanceFixtures.organizationAvailable))
    func organizesRealItemThroughLane() async throws {
        let store = try makeStore()
        let item = try store.create()
        // Stage the real caso-02 transcript, exactly as the transcription lane would.
        let transcript = try String(contentsOf: AcceptanceFixtures.transcriptURL(case: "02"), encoding: .utf8)
        _ = try store.markQueued(item.id, duration: 17.3)
        _ = try store.markTranscribing(item.id)
        try store.write(Data(transcript.utf8), to: ItemFile.transcript, for: item.id)

        let lane = OrganizationLane(store: store, organizer: try AcceptanceFixtures.organizer())
        await lane.organize(item.id)
        await lane.waitUntilIdle()

        #expect(try store.meta(for: item.id).state == .organized)
        #expect(try store.read(file: ItemFile.pass1, for: item.id) != nil)
        let final = try #require(try store.finalText(for: item.id))
        // The fillers `Puts cara` / `né` are gone; the hedge `acho que` survives.
        #expect(final.localizedCaseInsensitiveContains("acho que"))
        #expect(!final.contains("Puts cara"))
    }

    // MARK: - Fixtures & helpers

    private func makeStore() throws -> ItemStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-lane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ItemStore(root: root)
    }

    /// Create an item, move it to `transcribing`, and write its transcript — the
    /// state and artifact the organization lane consumes.
    private func transcribedItem(in store: ItemStore, transcript: String) throws -> String {
        let item = try store.create()
        _ = try store.markQueued(item.id, duration: 1.0)
        _ = try store.markTranscribing(item.id)
        try store.write(Data(transcript.utf8), to: ItemFile.transcript, for: item.id)
        return item.id
    }
}

// MARK: - Test doubles for the `Organizing` seam

/// Deterministic two-pass transform: pass 1 wraps in ANNOTATED, pass 2 in REWRITTEN,
/// so a test can assert exactly which text was persisted where.
private struct FakeOrganizer: Organizing {
    static func annotated(_ t: String) -> String { "ANNOTATED[\(t)]" }
    static func rewritten(_ t: String) -> String { "REWRITTEN[\(t)]" }
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        Self.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        Self.rewritten(annotated)
    }
}

/// Always throws the given error from whichever pass its stage names.
private struct ThrowingOrganizer: Organizing {
    let error: OrganizationError
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        if case .failed(.pass1, _, _) = error { throw error }
        return FakeOrganizer.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        if case .failed(.pass2, _, _) = error { throw error }
        return FakeOrganizer.rewritten(annotated)
    }
}

/// Pass 1 succeeds (so `pass1.txt` is written); pass 2 fails. Proves the pivot is
/// retained across a pass-2 failure.
private struct Pass2FailingOrganizer: Organizing {
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        FakeOrganizer.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        throw .failed(stage: .pass2, reason: .cliError, detail: "pass 2 broke")
    }
}

/// Counts how many passes were invoked, to prove a skipped item never calls claude.
private actor CountingOrganizer: Organizing {
    private(set) var calls = 0
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        calls += 1
        return transcript
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        calls += 1
        return annotated
    }
}

/// Blocks in the named pass until its task is cancelled, then throws as a killed
/// `claude` would (non-JSON → `cliError`) carrying that pass's stage. Stands in for a
/// long pass that `cancel`/`shutdown` terminates.
private struct BlockingOrganizer: Organizing {
    let blockOn: Stage
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        if blockOn == .pass1 {
            await blockUntilCancelled()
            throw .failed(stage: .pass1, reason: .cliError, detail: "cancelled")
        }
        return FakeOrganizer.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        if blockOn == .pass2 {
            await blockUntilCancelled()
            throw .failed(stage: .pass2, reason: .cliError, detail: "cancelled")
        }
        return FakeOrganizer.rewritten(annotated)
    }
}

/// Records which passes ran (and their inputs), so a resume test can prove pass 1 was
/// skipped and pass 2 rewrote the retained pivot.
private actor RecordingOrganizer: Organizing {
    private(set) var annotateCalls = 0
    private(set) var rewriteInputs: [String] = []
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        annotateCalls += 1
        return FakeOrganizer.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        rewriteInputs.append(annotated)
        return FakeOrganizer.rewritten(annotated)
    }
}

/// Yield until the current task is cancelled — the co-operative block the cancellation
/// fakes use to stand in for a long-running shell-out.
private func blockUntilCancelled() async {
    while !Task.isCancelled { await Task.yield() }
}

/// A one-shot barrier: `arriveAndWait` blocks each caller until `expected` callers
/// have arrived, then releases them all. Used to prove the lane runs items in
/// parallel — a serial lane can never gather `expected` simultaneous arrivals.
private actor Rendezvous {
    private let expected: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { self.expected = expected }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= expected {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Each pass 1 arrives at the shared barrier before returning, so all items must be
/// in flight at once for any to finish.
private struct RendezvousOrganizer: Organizing {
    let rendezvous: Rendezvous
    func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        await rendezvous.arriveAndWait()
        return FakeOrganizer.annotated(transcript)
    }
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        FakeOrganizer.rewritten(annotated)
    }
}

/// Run `operation`, returning `true` if it finished within `seconds` and `false` if
/// the timeout won the race (so a deadlocked serial lane fails cleanly, never hangs).
private func withinTimeout(seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation(); return true }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// A thread-safe sink for the lane's callbacks (they fire on the actor).
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _organized: [String] = []
    private var _stateChanges = 0
    func addOrganized(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        _organized.append(id)
    }
    func bumpState() {
        lock.lock(); defer { lock.unlock() }
        _stateChanges += 1
    }
    var organized: [String] {
        lock.lock(); defer { lock.unlock() }
        return _organized
    }
}

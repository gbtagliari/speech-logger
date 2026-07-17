import Foundation

/// The cross-cutting control of in-flight work (issue #22, ADR-0006): the manual
/// "stop processing", resume-from-stage retry, and a graceful quit that never blocks.
/// It sits above the three lanes — recording, transcription, organization — and routes
/// each control to whichever owns the item, keeping that coordination out of the
/// AppKit layer and behind a testable seam.
///
/// `@MainActor` because it drives the `@MainActor` recording coordinator and reads the
/// store synchronously; the two lanes are actors it awaits into.
@MainActor public final class PipelineController {
    private let store: ItemStore
    private let recording: RecordingCoordinator
    private let transcription: TranscriptionLane
    /// Optional: organization is disabled (nil) when the prompts fail to load — a
    /// packaging error in which no item ever organizes, so there is nothing to stop,
    /// resume, or shut down on that lane.
    private let organization: OrganizationLane?

    /// Fired after a control changes item state synchronously (a retry's re-entry, the
    /// quit sweep), so the menubar can recompute. The lanes fire their own on the
    /// transitions they drive; this covers the writes the controller makes directly.
    public var onStateChange: (@MainActor () -> Void)?

    public init(
        store: ItemStore,
        recording: RecordingCoordinator,
        transcription: TranscriptionLane,
        organization: OrganizationLane?
    ) {
        self.store = store
        self.recording = recording
        self.transcription = transcription
        self.organization = organization
    }

    // MARK: - Stop (story 30, 31)

    /// Manually stop an in-flight processing item. Routed to both lanes; the one that
    /// owns the id kills its subprocess and records `cancelled` (distinct from
    /// `failed`, and retryable). An id neither lane is running — already terminal, or a
    /// `recording` item, which the hotkey controls, not this — is a no-op.
    public func stop(_ id: String) {
        Task {
            await transcription.cancel(id)
            await organization?.cancel(id)
        }
    }

    // MARK: - Retry (story 29)

    /// Retry a `failed`/`cancelled` item from the stage it died at, reusing the
    /// retained artifacts. A transcription-stage resume re-enters the serial lane
    /// (reusing `audio.mp3`); a pass-1/pass-2 resume re-enters the parallel lane
    /// (reusing `transcript.txt`, and `pass1.txt` for pass 2). A `recording`-stage
    /// death has nothing to resume and is delete-only, so it is ignored here.
    public func retry(_ id: String) {
        guard let stage = resumeStage(for: id) else { return }
        switch stage {
        case .transcription:
            _ = try? store.requeueForRetry(id)
            onStateChange?()
            Task { await transcription.enqueue(id) }
        case .pass1, .pass2:
            guard let organization else { return }  // organization disabled; cannot resume
            _ = try? store.resumeForOrganizing(id)
            onStateChange?()
            Task { await organization.organize(id, from: stage) }
        case .recording:
            break  // unreachable: `resumeStage` filters a recording death out
        }
    }

    /// The stage a retryable item should resume from, or `nil` when it cannot be
    /// retried (not a terminal off-ramp, or a `recording` death with nothing to reuse).
    private func resumeStage(for id: String) -> Stage? {
        guard let stage = try? store.meta(for: id).deathStage, stage != .recording else { return nil }
        return stage
    }

    // MARK: - Reprocess (#24)

    /// Re-run a settled item whole: discard everything derived from `audio.mp3` and
    /// re-enter the serial transcription lane from `queued`, so the transcription and
    /// both passes run again over fresh text.
    ///
    /// Distinct from `retry`, which resumes from the death stage and *reuses* the
    /// retained artifacts. Reprocess exists because retry cannot reach the failure #24
    /// documents: a pass can return fluent text that is not the dictation at all (there,
    /// a chat reply), and the SPEC deliberately does not judge fidelity at runtime, so
    /// the item lands `organized` with no error and no stage to resume from. Short of
    /// this, the only recovery is deleting the item and speaking it again.
    ///
    /// It always re-enters at transcription, never at a pass: the stage that produced
    /// the bad text is not knowable (nothing failed), so re-running the lot is the only
    /// honest answer. An item still in flight, or one whose recording never produced
    /// audio, is a no-op.
    public func reprocess(_ id: String) {
        guard let meta = try? store.meta(for: id),
            Item(id: id, meta: meta).isReprocessable
        else { return }
        // Organization is disabled (the prompts failed to load — a packaging error).
        // Refuse: this is the one control that destroys before it rebuilds, and with no
        // organization lane the rebuild never comes. It would drop `final.txt` and park
        // the item at `transcribing` forever, losing text that was fine. Retry can skip
        // this guard for a transcription resume because it deletes nothing.
        guard organization != nil else { return }
        // The requeue is what makes the item `queued`, and the lane picks up nothing
        // else — so a failed write must stop here rather than fall through to an
        // `enqueue` that would quietly do nothing. Unlike retry, this click cost the
        // user a confirmation, so "nothing happened" is the one outcome to rule out:
        // the item stays as it was, still `organized`, still offering the menu entry.
        guard (try? store.requeueForReprocess(id)) != nil else { return }
        onStateChange?()
        Task { await transcription.enqueue(id) }
    }

    // MARK: - Graceful quit (story 35, ADR-0006)

    /// Quit without ever blocking. A recording in progress is discarded silently (it
    /// has nothing to resume). Every in-flight processing item is marked `cancelled`
    /// authoritatively *first* — a synchronous, durable store write — and only then are
    /// the lanes shut down, sending each subprocess SIGTERM. Quit does not wait for the
    /// processes to die; the marks are already on disk, and each lane's process handler
    /// sees the item already terminal and leaves it. A crash/force-kill instead falls
    /// through to boot recovery.
    public func quitGracefully() async {
        recording.discardIfRecording()

        for item in (try? store.list()) ?? [] {
            switch item.state {
            case .queued, .transcribing:
                _ = try? store.cancel(item.id, stage: .transcription)
            case .organizing:
                // Pinpoint the pass from the surviving pivot so retry resumes right.
                _ = try? store.cancel(item.id, stage: store.organizingResumeStage(for: item.id))
            case .recording, .organized, .failed, .cancelled:
                break
            }
        }
        onStateChange?()

        await transcription.shutdown()
        await organization?.shutdown()
    }
}

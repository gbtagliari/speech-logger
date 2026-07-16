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
        guard let meta = try? store.meta(for: id) else { return nil }
        let stage: Stage?
        switch meta.state {
        case .failed: stage = meta.error?.stage
        case .cancelled: stage = meta.stoppedAt?.stage
        case .recording, .queued, .transcribing, .organizing, .organized: return nil
        }
        guard let stage, stage != .recording else { return nil }
        return stage
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
                let stage: Stage = store.hasContent(ItemFile.pass1, for: item.id) ? .pass2 : .pass1
                _ = try? store.cancel(item.id, stage: stage)
            case .recording, .organized, .failed, .cancelled:
                break
            }
        }
        onStateChange?()

        await transcription.shutdown()
        await organization?.shutdown()
    }
}

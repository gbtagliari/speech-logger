import AVFoundation
import AppKit
import SpeechLoggerCore
import os

/// Assembles and owns the app: the item store, the menubar, the global hotkey, and
/// the recording pipeline (record → guard → encode → `queued`). The heavy logic
/// lives in `SpeechLoggerCore` behind seams (`RecordingCoordinator`, `HotkeyDetector`);
/// this target is the thin AppKit/AVFoundation wiring.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.speech-logger", category: "app")

    private var store: ItemStore?
    private var coordinator: RecordingCoordinator?
    private var transcriptionLane: TranscriptionLane?
    private var organizationLane: OrganizationLane?
    private var pipelineController: PipelineController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var menubar: MenubarController?
    private var readyNotifier: ReadyNotifier?
    /// The prerequisite check (SPEC "First-run preflight"): read at launch, re-read on
    /// focus and panel-open. It reports; it never gates the hotkey.
    private var preflight = PreflightReport.satisfied
    /// Set once the graceful-quit sweep is running, so a re-entrant terminate request
    /// falls straight through instead of starting a second sweep.
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm the microphone grant so the first hotkey recording is not lost to a
        // pending prompt. Harmless if already decided.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        let store = makeStore()
        self.store = store

        // Boot recovery: any item left mid-pipeline by a crash/quit is stuck on a
        // fresh process, so mark it failed/interrupted (ADR-0006).
        do {
            let recovered = try store.recoverOrphans()
            if !recovered.isEmpty { log.info("recovered \(recovered.count) orphaned item(s) on boot") }
        } catch {
            log.error("boot recovery failed: \(String(describing: error))")
        }

        let menubar = MenubarController()
        // Panel-open is one of preflight's two re-check moments (SPEC): the panel is
        // where the failures are read, so it must not show a stale one.
        menubar.onPanelWillOpen = { [weak self] in self?.refreshPreflight() }
        menubar.viewModel.onOpenSettings = { InputMonitoring.openSettings() }
        menubar.viewModel.onDownloadModel = { [weak self] in self?.downloadWhisperModel() }
        menubar.viewModel.onQuit = { NSApp.terminate(nil) }
        menubar.viewModel.onCopy = { [weak self] id in self?.copyFinalText(of: id) }
        menubar.viewModel.onDelete = { [weak self] id in self?.deleteItem(id) }
        menubar.viewModel.onRetry = { [weak self] id in self?.pipelineController?.retry(id) }
        menubar.viewModel.onStop = { [weak self] id in self?.pipelineController?.stop(id) }
        menubar.viewModel.onOpenFolder = { [weak self] id in self?.openFolder(of: id) }
        self.menubar = menubar

        // The ready signal (stories 21, 27): one notification per organized item, with
        // a `Copiar` that copies straight from the banner. Authorization is asked for
        // at launch so the first ready item is not lost to a pending prompt; a denial
        // degrades to the panel and never blocks the pipeline.
        let readyNotifier = ReadyNotifier()
        readyNotifier.onCopy = { [weak self] id in self?.copyFinalText(of: id) }
        readyNotifier.requestAuthorization()
        self.readyNotifier = readyNotifier

        // The unbounded parallel organization lane (ADR-0001, ADR-0006): drip-fed by
        // the transcription lane, it runs the two `claude` passes (`organizing` ->
        // `organized`). The prompts ship as bundled resources; if they cannot load
        // (a packaging error), organization is left unwired and transcribed items
        // rest at `transcribing` rather than failing every one on a missing prompt.
        let organizationLane = makeOrganizationLane(store: store)
        self.organizationLane = organizationLane

        // The single serial transcription lane (ADR-0006): items land `queued`, this
        // picks them up one at a time and writes the raw transcript, then hands the
        // item to the organization lane the instant its text exists.
        let lane = TranscriptionLane(
            store: store,
            transcriber: Transcriber(),
            onStateChange: { [weak self] in Task { @MainActor in self?.refresh() } },
            onTranscribed: { [weak organizationLane] id in
                Task { await organizationLane?.organize(id) }
            })
        self.transcriptionLane = lane

        let coordinator = RecordingCoordinator(
            store: store, recorder: AudioRecorder(), encoder: AudioEncoder())
        coordinator.onStateChange = { [weak self] in self?.refresh() }
        coordinator.onQueued = { [weak lane] id in Task { await lane?.enqueue(id) } }
        coordinator.onRecorderStartFailed = { [weak self] error in
            self?.log.error("recording could not start: \(String(describing: error))")
        }
        self.coordinator = coordinator

        // The cross-cutting control of in-flight work (#22, ADR-0006): manual stop,
        // resume-from-stage retry, and the graceful quit. It routes each control to
        // whichever lane owns the item; its own state writes (a retry's re-entry, the
        // quit sweep) fire `onStateChange` so the menubar recomputes.
        let controller = PipelineController(
            store: store, recording: coordinator,
            transcription: lane, organization: organizationLane)
        controller.onStateChange = { [weak self] in self?.refresh() }
        self.pipelineController = controller

        let hotkeyMonitor = HotkeyMonitor(onToggle: { [weak coordinator] in coordinator?.toggle() })
        self.hotkeyMonitor = hotkeyMonitor

        installHotkey()
        // The launch-time read, which also does the first `refresh()`.
        refreshPreflight()
    }

    /// Graceful quit that never blocks (story 35, ADR-0006). Defer termination just
    /// long enough for the controller to discard an in-progress recording and mark
    /// in-flight processing `cancelled` (durable store writes) and to send each
    /// subprocess SIGTERM — it does *not* wait for the processes to die, so the user is
    /// never blocked. A re-entrant request (or no controller yet) terminates at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = pipelineController, !isQuitting else { return .terminateNow }
        isQuitting = true
        Task { @MainActor in
            await controller.quitGracefully()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }

    /// Focus is preflight's other re-check moment (SPEC): the user leaves to install a
    /// binary or flip the Settings toggle and comes back, and the report must follow.
    ///
    /// The Input Monitoring grant is the one check that will not move here — it is a
    /// launch-time read, so a fresh grant needs a relaunch (ADR-0005) — but the retry
    /// is cheap and recovers if the monitor can now be installed after all.
    func applicationDidBecomeActive(_ notification: Notification) {
        if preflight.needsPermission { installHotkey() }
        refreshPreflight()
    }

    // MARK: - Wiring

    private func installHotkey() {
        let granted = hotkeyMonitor?.start() ?? false
        if !granted {
            // Prompts once iff no prior TCC decision; otherwise a no-op and the
            // menubar's Settings deep-link is the path.
            InputMonitoring.request()
        }
    }

    /// Re-read the prerequisites and push the result to the menubar. Cheap (five
    /// `stat`s and a `CGPreflightListenEventAccess()`), so it can ride the launch,
    /// focus and panel-open moments the SPEC asks for.
    ///
    /// Nothing here gates recording: a prerequisite missing at capture time still
    /// records, and the item lands as a retryable `failed`/`missing_binary` from the
    /// lane that hits it (story 40).
    private func refreshPreflight() {
        preflight = Preflight.run(inputMonitoringGranted: InputMonitoring.isGranted)
        refresh()
    }

    /// Download the Whisper model — the one prerequisite preflight fixes (story 39),
    /// on the user's click. Long (~1.5 GB) and nothing waits on it: the panel shows it
    /// running, and the re-check afterwards is what clears the banner. A failure stays
    /// a failure in the report, so the click is simply offered again.
    private func downloadWhisperModel() {
        guard let menubar, !menubar.viewModel.isDownloadingModel else { return }
        menubar.viewModel.isDownloadingModel = true
        Task { @MainActor [weak self] in
            do {
                try await WhisperModelDownloader().download()
            } catch {
                self?.log.error("whisper model download failed: \(String(describing: error))")
            }
            self?.menubar?.viewModel.isDownloadingModel = false
            self?.refreshPreflight()
        }
    }

    /// Recompute both the glyph and the panel from the current item list and push
    /// them to the menubar. The single refresh path, fired after every state change.
    private func refresh() {
        let items = (try? store?.list()) ?? []
        let state = MenubarState.resolve(
            items: items,
            isRecording: coordinator?.isRecording ?? false,
            preflight: preflight)
        menubar?.update(state)

        let model = PanelModel.build(
            items: items,
            now: Date(),
            finalText: { [weak self] id in
                guard let self, let store = self.store else { return nil }
                do {
                    return try store.finalText(for: id)
                } catch {
                    self.log.error(
                        "preview text unavailable for \(id, privacy: .public): \(String(describing: error))")
                    return nil
                }
            })
        menubar?.updatePanel(model, preflight: preflight)
    }

    /// Raise the ready notification for a just-organized item (stories 21, 27). Fired
    /// once per item by the organization lane, on reaching `organized`.
    ///
    /// An unreadable final text still notifies (on the fallback body): the read is the
    /// banner's preview, not its purpose, and losing the ready signal over it would
    /// leave the item silently done. `Copiar` re-reads the store at tap time.
    private func notifyReady(_ id: String) {
        guard let store, let readyNotifier else { return }
        let preview: String
        do {
            // nil means the item is no longer `organized` — deleted between the lane's
            // callback and this read. Then there is nothing left to announce.
            guard let text = try store.finalText(for: id) else { return }
            preview = text
        } catch {
            log.error(
                "ready notification has no preview text for \(id, privacy: .public): \(String(describing: error))")
            preview = ""
        }
        readyNotifier.notifyReady(id: id, finalText: preview)
    }

    /// Copy an organized item's final pass-2 text to the clipboard (story 22). Only
    /// `organized` items return text, so nothing partial is ever copyable as final.
    private func copyFinalText(of id: String) {
        guard let text = try? store?.finalText(for: id) else {
            log.error("copy requested for \(id, privacy: .public) with no final text")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Send an item to the macOS Trash (stories 25, 26), then refresh the panel.
    private func deleteItem(_ id: String) {
        do {
            try store?.delete(id)
        } catch {
            log.error("delete failed for \(id, privacy: .public): \(String(describing: error))")
        }
        refresh()
    }

    /// Open an item's directory in Finder, so its artifacts are reachable when the
    /// panel's preview is not enough — a failed organization still has `transcript.txt`
    /// and `pass1.txt` on disk. Read-only: the store is never touched.
    private func openFolder(of id: String) {
        guard let url = try? store?.directoryURL(for: id) else {
            log.error("open folder requested for \(id, privacy: .public) with no directory")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Build the organization lane, loading the two bundled prompts. If they cannot
    /// load — a build/packaging error, never expected at runtime — organization is
    /// disabled (nil): transcribed items rest at `transcribing` rather than every one
    /// failing on a missing prompt. It is not a preflight check: preflight is about the
    /// user's machine, and a bundled resource that did not ship is our bug, logged here.
    /// When wired, the lane advances `organizing` -> `organized` and raises the ready
    /// notification via `onOrganized`.
    private func makeOrganizationLane(store: ItemStore) -> OrganizationLane? {
        let prompts: Prompts
        do {
            prompts = try Prompts.bundled()
        } catch {
            log.error("organization disabled; prompts failed to load: \(String(describing: error))")
            return nil
        }
        return OrganizationLane(
            store: store,
            organizer: ClaudeOrganizer(prompts: prompts),
            onStateChange: { [weak self] in Task { @MainActor in self?.refresh() } },
            onOrganized: { [weak self] id in
                Task { @MainActor in self?.notifyReady(id) }
            })
    }

    private func makeStore() -> ItemStore {
        do {
            return ItemStore(root: try ItemStore.defaultRoot())
        } catch {
            // Application Support is unavailable: fall back to a temp root so the app
            // still runs (degraded), rather than crashing on launch.
            log.error("using a temp store root; Application Support unavailable: \(String(describing: error))")
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-logger", isDirectory: true)
                .appendingPathComponent("items", isDirectory: true)
            return ItemStore(root: fallback)
        }
    }
}

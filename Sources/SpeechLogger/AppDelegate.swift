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
    private var hotkeyMonitor: HotkeyMonitor?
    private var menubar: MenubarController?
    /// True when Input Monitoring is not granted; drives the degraded glyph.
    private var needsPermission = false

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
        menubar.onOpenInputMonitoringSettings = { InputMonitoring.openSettings() }
        menubar.onQuit = { NSApp.terminate(nil) }
        self.menubar = menubar

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
            onStateChange: { [weak self] in Task { @MainActor in self?.refreshIcon() } },
            onTranscribed: { [weak organizationLane] id in
                Task { await organizationLane?.organize(id) }
            })
        self.transcriptionLane = lane

        let coordinator = RecordingCoordinator(
            store: store, recorder: AudioRecorder(), encoder: AudioEncoder())
        coordinator.onStateChange = { [weak self] in self?.refreshIcon() }
        coordinator.onQueued = { [weak lane] id in Task { await lane?.enqueue(id) } }
        coordinator.onRecorderStartFailed = { [weak self] error in
            self?.log.error("recording could not start: \(String(describing: error))")
        }
        self.coordinator = coordinator

        let hotkeyMonitor = HotkeyMonitor(onToggle: { [weak coordinator] in coordinator?.toggle() })
        self.hotkeyMonitor = hotkeyMonitor

        installHotkey()
        refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }

    /// A grant does not update preflight live within a process (it is a launch-time
    /// read), so this mostly no-ops until relaunch — but it is cheap and recovers if
    /// the monitor can now be installed.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard needsPermission else { return }
        installHotkey()
        refreshIcon()
    }

    // MARK: - Wiring

    private func installHotkey() {
        let granted = hotkeyMonitor?.start() ?? false
        needsPermission = !granted
        if !granted {
            // Prompts once iff no prior TCC decision; otherwise a no-op and the
            // menubar's Settings deep-link is the path.
            InputMonitoring.request()
        }
    }

    private func refreshIcon() {
        let items = (try? store?.list()) ?? []
        let state = MenubarState.resolve(
            items: items,
            isRecording: coordinator?.isRecording ?? false,
            needsPermission: needsPermission)
        menubar?.update(state)
    }

    /// Build the organization lane, loading the bundled prompts. On a load failure the
    /// organizer still runs but every pass fails `missing_binary`-style — so instead we
    /// log and wire it with the prompts we have; a missing prompt is a build error that
    /// preflight (a later ticket) will surface. The lane advances `organizing` ->
    /// `organized` and, later, will raise the ready notification via `onOrganized`.
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
            onStateChange: { [weak self] in Task { @MainActor in self?.refreshIcon() } },
            onOrganized: { [weak self] id in
                Task { @MainActor in self?.log.info("organized \(id, privacy: .public)") }
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

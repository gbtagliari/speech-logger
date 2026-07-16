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

        let coordinator = RecordingCoordinator(
            store: store, recorder: AudioRecorder(), encoder: AudioEncoder())
        coordinator.onStateChange = { [weak self] in self?.refreshIcon() }
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

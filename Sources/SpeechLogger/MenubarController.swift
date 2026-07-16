import AppKit
import SpeechLoggerCore

/// Owns the status item and renders the priority-ladder glyph plus, while
/// recording, a running clock (SPEC "UI", stories 5 and 6). One glyph, one state
/// (`MenubarState`). The full three-section panel (Prontos / Precisam de você) is
/// a later ticket; this build shows the recording clock and the degraded
/// Input-Monitoring path.
@MainActor final class MenubarController {
    private let statusItem: NSStatusItem
    private var state: MenubarState = .idle
    private var clockTimer: Timer?
    private var recordingSeconds = 0

    /// Deep-link to the Input Monitoring pane (shown in the degraded state).
    var onOpenInputMonitoringSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
    }

    /// Reflect a new app state. Starts/stops the running clock on entering/leaving
    /// `recording`.
    func update(_ state: MenubarState) {
        let wasRecording = self.state == .recording
        self.state = state
        if state == .recording, !wasRecording {
            startClock()
        } else if state != .recording, wasRecording {
            stopClock()
        }
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let symbol = Self.symbolName(for: state)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.image?.isTemplate = true
        button.title = state == .recording ? " \(Self.clockText(recordingSeconds))" : ""
        statusItem.menu = makeMenu()
    }

    private var accessibility: String {
        switch state {
        case .recording: return "speech logger — gravando"
        case .failed: return "speech logger — falha"
        case .needsPermission: return "speech logger — precisa de permissão"
        case .processing: return "speech logger — processando"
        case .idle: return "speech logger"
        }
    }

    /// The one glyph per state. Template images inherit the menubar's tint.
    private static func symbolName(for state: MenubarState) -> String {
        switch state {
        case .recording: return "record.circle"
        case .failed: return "exclamationmark.triangle"
        case .needsPermission: return "exclamationmark.lock"
        case .processing: return "hourglass"
        case .idle: return "waveform"
        }
    }

    private static func clockText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Clock

    private func startClock() {
        recordingSeconds = 0
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingSeconds += 1
                self.render()
            }
        }
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        recordingSeconds = 0
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let heading = NSMenuItem(title: "speech logger", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        switch state {
        case .recording:
            let status = NSMenuItem(
                title: "Gravando  \(Self.clockText(recordingSeconds))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        case .needsPermission:
            let note = NSMenuItem(
                title: "Monitoramento de Entrada desativado", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            let open = NSMenuItem(
                title: "Abrir Ajustes do Sistema…", action: #selector(openSettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let hint = NSMenuItem(
                title: "Depois de permitir, reabra o app.", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        case .failed, .processing, .idle:
            break
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openSettings() { onOpenInputMonitoringSettings?() }
    @objc private func quit() { onQuit?() }
}

import AppKit
import SpeechLoggerCore
import SwiftUI

/// Owns the status item: renders the priority-ladder glyph plus, while recording, a
/// running clock (SPEC "UI", stories 5, 6), and hangs the three-section panel off
/// the button as an `NSPopover` hosting a SwiftUI `PanelView`. The glyph is one
/// state (`MenubarState`); the panel is a `PanelModel`. `AppDelegate` pushes both on
/// every app state change and wires the row actions through `viewModel`.
@MainActor final class MenubarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// The observable state behind the panel. `AppDelegate` sets its action closures.
    let viewModel = PanelViewModel()

    private var state: MenubarState = .idle
    private var clockTimer: Timer?
    private var recordingSeconds = 0

    /// Called just before the panel opens, so the app can refresh the item list and
    /// re-check permission (SPEC: preflight re-checks on panel-open).
    var onPanelWillOpen: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(viewModel: viewModel))
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        render()
    }

    /// Reflect a new glyph state. Starts/stops the running clock on entering/leaving
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

    /// Push a fresh panel model into the view (SPEC "UI"). `needsPermission` drives
    /// the degraded banner shown inside the panel.
    func updatePanel(_ model: PanelModel, needsPermission: Bool) {
        viewModel.model = model
        viewModel.needsPermission = needsPermission
    }

    // MARK: - Glyph rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let symbol = Self.symbolName(for: state)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.image?.isTemplate = true
        button.title = state == .recording ? " \(Self.clockText(recordingSeconds))" : ""
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
        viewModel.recordingSeconds = 0
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingSeconds += 1
                self.viewModel.recordingSeconds = self.recordingSeconds
                self.render()
            }
        }
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        recordingSeconds = 0
        viewModel.recordingSeconds = 0
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            onPanelWillOpen?()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

import Combine
import SpeechLoggerCore

/// The observable state behind the SwiftUI panel. `MenubarController` owns it and
/// pushes a fresh `PanelModel` on every app state change; `AppDelegate` wires the
/// row actions. Keeping the view a pure render of this object means the panel logic
/// stays in `SpeechLoggerCore.PanelModel` (tested), not in the view.
@MainActor
final class PanelViewModel: ObservableObject {
    /// The three sections, rebuilt from the item list on each refresh.
    @Published var model = PanelModel(live: [], ready: [], needsYou: [])
    /// The launch-time prerequisite check: its failures are the panel's degraded
    /// banner. Re-read on focus and panel-open, never a modal.
    @Published var preflight = PreflightReport.satisfied
    /// The model download is running: the fix is in flight, so the banner shows
    /// progress instead of offering the click again.
    @Published var isDownloadingModel = false
    /// Why the last download click failed, in pt-BR, or nil if none has. Without it a
    /// dead network would stop the spinner and change nothing else on screen.
    @Published var modelDownloadFailure: String?
    /// The live recording clock, driven by the menubar's per-second timer so the
    /// panel's *Acontecendo agora* clock matches the menubar title exactly.
    @Published var recordingSeconds = 0

    /// Copy an organized item's final pass-2 text to the clipboard.
    var onCopy: (String) -> Void = { _ in }
    /// Send an item to the macOS Trash.
    var onDelete: (String) -> Void = { _ in }
    /// Retry a failed/cancelled item from the stage it died at.
    var onRetry: (String) -> Void = { _ in }
    /// Re-run an item whole, from its audio, discarding what the last run produced
    /// (#24). Confirms first — it throws away the current final text.
    var onReprocess: (String) -> Void = { _ in }
    /// Stop an in-flight processing item — queued/transcribing/organizing.
    var onStop: (String) -> Void = { _ in }
    /// Reveal an item's directory in Finder, so its artifacts (audio, transcript,
    /// the two passes) are reachable when the panel's preview is not enough.
    var onOpenFolder: (String) -> Void = { _ in }
    /// Deep-link to the Input Monitoring pane (degraded state).
    var onOpenSettings: () -> Void = {}
    /// Download the Whisper model — the one prerequisite preflight can fix.
    var onDownloadModel: () -> Void = {}
    var onQuit: () -> Void = {}
}

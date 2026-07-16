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
    /// Input Monitoring is not granted: show the degraded banner and its deep-link.
    @Published var needsPermission = false
    /// The live recording clock, driven by the menubar's per-second timer so the
    /// panel's *Acontecendo agora* clock matches the menubar title exactly.
    @Published var recordingSeconds = 0

    /// Copy an organized item's final pass-2 text to the clipboard (story 22).
    var onCopy: (String) -> Void = { _ in }
    /// Send an item to the macOS Trash (stories 25, 26).
    var onDelete: (String) -> Void = { _ in }
    /// Retry a failed/cancelled item from the stage it died at (story 29).
    var onRetry: (String) -> Void = { _ in }
    /// Stop an in-flight processing item — queued/transcribing/organizing (story 30).
    var onStop: (String) -> Void = { _ in }
    /// Reveal an item's directory in Finder, so its artifacts (audio, transcript,
    /// the two passes) are reachable when the panel's preview is not enough.
    var onOpenFolder: (String) -> Void = { _ in }
    /// Deep-link to the Input Monitoring pane (degraded state).
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
}

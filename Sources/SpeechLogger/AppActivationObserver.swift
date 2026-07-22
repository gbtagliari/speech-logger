import AppKit

/// The thin workspace adapter that feeds the auto-paste guard: it turns
/// `NSWorkspace.didActivateApplicationNotification` into one callback and knows nothing
/// else. The decision it feeds lives in `SpeechLoggerCore.AutoPasteGuard`, deliberately
/// **outside** this, so the whole state machine is testable with no window server.
///
/// It does not ask *which* app was activated, and there is nothing to add by asking:
/// any activation disarms, including this app's own. Because it observes continuously
/// rather than comparing a before/after snapshot, an app that quits and reopens is not
/// a special case — it produces an activation either way.
@MainActor final class AppActivationObserver {
    /// Some app came to the front.
    var onActivate: (@MainActor () -> Void)?

    private var token: (any NSObjectProtocol)?

    /// Start observing. Idempotent: a second call while observing is a no-op.
    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Workspace notifications on `.main` are delivered on the main thread.
            MainActor.assumeIsolated { self?.onActivate?() }
        }
    }

    /// Stop observing. Paired with `start` on the app's lifetime the way the hotkey
    /// monitor is, rather than left to `deinit` — the token is main-actor state, and a
    /// nonisolated `deinit` cannot reach it.
    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}

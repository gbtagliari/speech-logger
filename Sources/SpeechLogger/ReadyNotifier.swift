import SpeechLoggerCore
import UserNotifications
import os

/// Raises the ready signal: one macOS notification per `organized` item, carrying a
/// `Copiar` that puts the final pass-2 text on the clipboard straight from the banner
/// and a `Dispensar` alongside (SPEC "UI", stories 21, 27). It never opens the app.
///
/// The thin `UserNotifications` wiring around `ReadyNotification`, which decides what
/// the banner says. Local notifications need no entitlement — only the user's
/// authorization, requested at launch and handled by degrading to the panel if denied.
@MainActor
final class ReadyNotifier: NSObject {
    private let log = Logger(subsystem: "app.speech-logger", category: "notification")
    private let center: UNUserNotificationCenter

    /// The category the two buttons hang off. Every ready notification declares it.
    private static let categoryIdentifier = "ready"
    private static let copyActionIdentifier = "ready.copy"
    private static let dismissActionIdentifier = "ready.dismiss"

    /// Fired with the item id when the user taps `Copiar`. The app copies from the
    /// store, so the banner never carries a stale duplicate of the text.
    var onCopy: ((String) -> Void)?

    /// The in-flight authorization request. `notifyReady` awaits it before posting:
    /// an item can finish organizing while the prompt is still up, and posting into a
    /// pending decision drops the banner for good (`organized` is terminal, so nothing
    /// ever re-fires it). Held as a task, so the many-items case awaits one request.
    private var authorization: Task<Bool, Never>?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories([Self.category])
    }

    /// The two buttons. Neither takes `.foreground`: an action must not activate the
    /// app, which is the "never opens the app" rule. `Dispensar` is `.destructive`
    /// only for the visual weight — it discards nothing, the item stays in the panel.
    private static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: copyActionIdentifier, title: "Copiar"),
                UNNotificationAction(
                    identifier: dismissActionIdentifier, title: "Dispensar",
                    options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [])
    }

    /// Ask for banner authorization. Called once at launch, so the prompt is answered
    /// long before the first item finishes the pipeline. A denial is logged and the
    /// app degrades to the panel as the only ready signal, never blocking anything.
    func requestAuthorization() {
        guard authorization == nil else { return }
        authorization = Task { [center, log] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                if !granted {
                    log.warning("notifications denied; the panel is the only ready signal")
                }
                return granted
            } catch {
                log.error("notification authorization failed: \(String(describing: error))")
                return false
            }
        }
    }

    /// Post the ready banner for one organized item, once per item and never batched
    /// with another (story 27). One-per-item is the organization lane's doing — it
    /// fires `onOrganized` only on the `markOrganized` transition, and `organized` is
    /// terminal, so no retry re-enters it. Using the item id as the request identifier
    /// is the belt to that braces: were it ever to fire twice, the second post would
    /// replace the first banner in place instead of stacking a duplicate.
    ///
    /// A denied authorization makes this a no-op, which is the intended degrade: the
    /// panel is then the only ready signal.
    func notifyReady(id: String, finalText: String) {
        let ready = ReadyNotification.build(id: id, finalText: finalText)

        let content = UNMutableNotificationContent()
        content.title = ready.title
        content.body = ready.body
        content.categoryIdentifier = Self.categoryIdentifier

        // A nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: ready.id, content: content, trigger: nil)
        Task { [center, log] in
            // Settle authorization first: posting into a still-pending prompt loses the
            // banner permanently, since nothing re-fires a terminal `organized` item.
            guard await authorization?.value ?? false else { return }
            do {
                try await center.add(request)
            } catch {
                log.error(
                    "ready notification failed for \(id, privacy: .public): \(String(describing: error))")
            }
        }
    }
}

extension ReadyNotifier: UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is frontmost (it can be, with the panel
    /// open). Without this the system would swallow it and the ready signal would go
    /// missing exactly when the item was just spoken.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Route a tapped button. `Copiar` copies; `Dispensar` and a tap on the banner
    /// body (the default action) do nothing.
    ///
    /// "Never opens the app" (SPEC "UI") is not enforceable from here: the system
    /// activates the app on the default action *before* this is called, and no
    /// category option suppresses that. What makes it true is `LSUIElement` — an
    /// accessory app has no window to open, so an activation is invisible. Keeping the
    /// body tap a no-op is the other half: it is never a way in.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // `response` is not Sendable: read what is needed before hopping to the actor.
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        Task { @MainActor in
            if action == Self.copyActionIdentifier { onCopy?(id) }
            completionHandler()
        }
    }
}

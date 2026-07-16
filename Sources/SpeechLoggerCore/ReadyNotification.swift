import Foundation

/// The ready notification as a pure value (SPEC "UI", stories 21, 27): what the
/// banner says for one `organized` item, decided without `UserNotifications`. The
/// framework wiring — authorization, the `Copiar`/`Dispensar` buttons, delivery —
/// lives in the app target's `ReadyNotifier`; this is the part worth testing.
public struct ReadyNotification: Sendable {
    /// The banner's char cap. Tighter than the panel's `ReadyPreview.defaultMaxChars`
    /// because a notification shows fewer lines than a panel row; the banner is a
    /// "which thought was this?" cue, and `Copiar` is the payload.
    public static let previewMaxChars = 120

    /// Shown when an item somehow reaches `organized` with blank text. Never expected
    /// (`markOrganized` writes the final text first), but a blank banner would be an
    /// unreadable dead end next to a `Copiar` button.
    private static let emptyBody = "Texto pronto."

    /// The item id, passed verbatim as the delivery request identifier so a banner is
    /// addressable by the item it belongs to (`ReadyNotifier.notifyReady` explains
    /// what that buys).
    public let id: String
    public let title: String
    public let body: String

    /// Private: `build` is the only way to make one. The type exists so the banner's
    /// wording is decided in one tested place, not so callers can pick their own.
    private init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// Build the banner for an organized item from its final pass-2 text.
    public static func build(id: String, finalText: String) -> ReadyNotification {
        let preview = ReadyPreview.clamp(finalText, maxChars: previewMaxChars)
        return ReadyNotification(
            id: id,
            title: "Pronto",
            body: preview.isEmpty ? emptyBody : preview)
    }
}

import Testing

@testable import SpeechLoggerCore

/// The ready notification's content as a pure value. The `UNUserNotificationCenter`
/// wiring lives in the app target; everything decidable without it — the body preview,
/// the identity that keeps it one-per-item — is here.
struct ReadyNotificationTests {
    @Test("the body previews the final text")
    func bodyPreviewsFinalText() {
        let notification = ReadyNotification.build(id: "01ABC", finalText: "a nota organizada")
        #expect(notification.body == "a nota organizada")
    }

    @Test("the banner is addressed by its item id, so a re-post replaces rather than stacks")
    func identifierIsItemId() {
        // One-per-item is the organization lane's doing (it fires `onOrganized` once,
        // on a terminal transition). Carrying the id as the request identifier is the
        // belt to that braces: a second post would replace, never duplicate.
        #expect(ReadyNotification.build(id: "01ABC", finalText: "oi").id == "01ABC")
    }

    @Test("a long final text is clamped to the banner cap with an ellipsis")
    func longTextIsClamped() {
        let text = String(repeating: "palavra ", count: 100)
        let notification = ReadyNotification.build(id: "01ABC", finalText: text)
        #expect(notification.body.hasSuffix("…"))
        // The visible characters never exceed the cap (the ellipsis is extra).
        #expect(notification.body.dropLast().count <= ReadyNotification.previewMaxChars)
    }

    @Test("the banner preview is shorter than the panel's")
    func bannerPreviewIsShorterThanPanel() {
        // A banner shows fewer lines than the panel row, so it clamps tighter.
        #expect(ReadyNotification.previewMaxChars < ReadyPreview.defaultMaxChars)
    }

    @Test("paragraphed text collapses to one flowing line")
    func collapsesParagraphs() {
        let notification = ReadyNotification.build(
            id: "01ABC", finalText: "primeiro parágrafo.\n\nsegundo parágrafo.")
        #expect(notification.body == "primeiro parágrafo. segundo parágrafo.")
    }

    @Test("an empty final text falls back to a body, never a blank banner")
    func emptyTextGetsFallbackBody() {
        // Defensive: an `organized` item always has text, but a blank banner would be
        // an unreadable dead end — the Copiar button still has to make sense.
        #expect(ReadyNotification.build(id: "01ABC", finalText: "   \n ").body == "Texto pronto.")
    }

    @Test("the title names the ready item in pt-BR")
    func titleIsPortuguese() {
        #expect(ReadyNotification.build(id: "01ABC", finalText: "oi").title == "Pronto")
    }
}

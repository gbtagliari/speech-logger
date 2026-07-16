import Testing

@testable import SpeechLoggerCore

/// The *Prontos* preview is clamped to a char cap so the panel shows a few lines,
/// not one and not the whole text (SPEC "UI", story 23). Whitespace and newlines
/// collapse to single spaces so the clamp reads as flowing text, and the SwiftUI
/// view applies the visual 3-line limit on top of this bound.
struct ReadyPreviewTests {
    @Test("a short text is returned whole, with no ellipsis")
    func shortTextUnchanged() {
        #expect(ReadyPreview.clamp("uma nota curta", maxChars: 220) == "uma nota curta")
    }

    @Test("leading and trailing whitespace is trimmed")
    func trimsEnds() {
        #expect(ReadyPreview.clamp("  oi  \n", maxChars: 220) == "oi")
    }

    @Test("runs of whitespace and newlines collapse to single spaces")
    func collapsesWhitespace() {
        #expect(
            ReadyPreview.clamp("primeira linha\n\nsegunda   linha", maxChars: 220)
                == "primeira linha segunda linha")
    }

    @Test("a text longer than the cap is cut and gets an ellipsis")
    func longTextGetsEllipsis() {
        let text = String(repeating: "a", count: 300)
        let out = ReadyPreview.clamp(text, maxChars: 220)
        #expect(out.hasSuffix("…"))
        // The visible characters never exceed the cap (the ellipsis is extra).
        #expect(out.dropLast().count <= 220)
    }

    @Test("the cut lands on a word boundary, never mid-word")
    func cutsOnWordBoundary() {
        // Ten 10-char words separated by spaces; cap of 25 lands inside the third.
        let words = (0..<10).map { _ in "abcdefghij" }.joined(separator: " ")
        let out = ReadyPreview.clamp(words, maxChars: 25)
        #expect(out.hasSuffix("…"))
        // No partial word survives: every whitespace-separated token is a full word.
        let visible = out.dropLast()
        for token in visible.split(separator: " ") {
            #expect(token == "abcdefghij")
        }
    }

    @Test("a single word longer than the cap is hard-cut")
    func hardCutsAGiantWord() {
        let out = ReadyPreview.clamp(String(repeating: "x", count: 300), maxChars: 20)
        #expect(out == String(repeating: "x", count: 20) + "…")
    }

    @Test("a text exactly at the cap keeps no ellipsis")
    func exactlyAtCap() {
        let text = String(repeating: "a", count: 20)
        #expect(ReadyPreview.clamp(text, maxChars: 20) == text)
    }

    @Test("an empty text clamps to empty")
    func emptyStaysEmpty() {
        #expect(ReadyPreview.clamp("   \n  ", maxChars: 220) == "")
    }
}

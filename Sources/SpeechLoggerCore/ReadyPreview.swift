import Foundation

/// Clamps an organized item's final text into the short *Prontos* preview: a few
/// lines, not one and not the whole thing. Whitespace and newlines collapse to single
/// spaces so paragraphed text reads as one flowing snippet; the SwiftUI panel applies
/// the visual 3-line limit on top of this bound.
public enum ReadyPreview {
    /// The default character cap: enough to fill ~3 lines of the ~340-pt panel, so
    /// the reader can tell items apart without opening each.
    public static let defaultMaxChars = 220

    /// Collapse whitespace, then cut to `maxChars` on a word boundary, appending an
    /// ellipsis when anything was dropped. A short text is returned whole.
    public static func clamp(_ text: String, maxChars: Int = defaultMaxChars) -> String {
        let flowing = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flowing.count > maxChars else { return flowing }

        let cut = String(flowing.prefix(maxChars))
        // Prefer to end on a whole word: drop back to the last space, unless that
        // would leave nothing (a single word longer than the cap), which we hard-cut.
        if let lastSpace = cut.lastIndex(of: " ") {
            let onBoundary = cut[..<lastSpace]
            if !onBoundary.isEmpty { return onBoundary + "…" }
        }
        return cut + "…"
    }
}

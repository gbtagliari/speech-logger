import Foundation

/// One acceptance-set case: its transcript (the organization input) plus the
/// fidelity-contract expectations that any faithful output must satisfy, encoded so
/// they hold for *any* contract-respecting rewrite rather than a single exact string
/// (pass 1 is nondeterministic — `docs/research/claude-cli-shell-out-contract.md`).
/// The expectations are the documented failure modes from
/// `.scratch/dictation-tool/assets/acceptance-set.md`, turned into regression checks.
struct AcceptanceCase: Sendable {
    let id: String
    /// The transcript fed to the two passes.
    let transcript: String
    /// Idea count + slip check: content that must survive (a completed idea, or a
    /// plausible slip the tool must not "repair"). Matched case-insensitively with
    /// backticks stripped, so `/sync` matches `` `/sync` ``.
    let preservedIdeas: [String]
    /// Modal check: modal phrases whose force must survive intact.
    let survivingModals: [String]
    /// New-word diff + modal downgrade: text that must NOT appear unless it was in the
    /// transcript (a downgraded modal like `não deve`, or an inserted semantic-weight
    /// word like `diretamente`).
    let forbiddenInsertions: [String]
    /// Slip check for ASR noise: the span that must be kept verbatim and marked
    /// `[? ... ?]`, never rewritten into something fluent.
    let markedNoise: MarkedNoise?
}

/// An ASR-noise span (case 04's `se profissional`): it must appear inside a
/// `[? ... ?]` mark, and no fluent repair of it may appear anywhere.
struct MarkedNoise: Sendable {
    /// The span that must be marked, verbatim (e.g. `se profissional`).
    let span: String
    /// Forms that would only exist if the model *repaired* the noise — the true
    /// utterance was `se é proporcional`, unrecoverable from context, so `proporcional`
    /// appearing at all means it guessed (e.g. `["proporcional"]`).
    let repairedForms: [String]
}

/// The result of one of the four fidelity checks over a candidate.
struct FidelityCheck: Sendable {
    /// `idea count` | `new-word diff` | `modal check` | `slip check`.
    let name: String
    /// Human-readable descriptions of each violation; empty means the check passed.
    let violations: [String]
    var passed: Bool { violations.isEmpty }
}

/// Judges a candidate against the fidelity contract by its four checks
/// (`.scratch/dictation-tool/assets/fidelity-contract.md`, "How to test an output").
/// Deterministic and offline — the app never judges fidelity at runtime; this is the
/// developer-run regression yardstick (SPEC "Testing Decisions"). The checks are
/// intentionally invariant-based, not exact-match, so a faithful-but-differently-worded
/// rewrite passes while the documented failure modes (summarizing, inserting a
/// weighted word, downgrading a modal, repairing ASR noise) fail.
enum FidelityJudge {
    /// Run all four checks. A case with no `markedNoise` still gets a (trivially
    /// passing) slip check, so every candidate is reported against the full four.
    static func judge(candidate: String, case testCase: AcceptanceCase) -> [FidelityCheck] {
        [
            ideaCount(candidate: candidate, testCase),
            newWordDiff(candidate: candidate, testCase),
            modalCheck(candidate: candidate, testCase),
            slipCheck(candidate: candidate, testCase),
        ]
    }

    /// Check 1 — idea count: no completed idea may disappear. Approximated as: every
    /// preserved-idea anchor still appears. A summarizing model drops one and fails.
    static func ideaCount(candidate: String, _ testCase: AcceptanceCase) -> FidelityCheck {
        let hay = normalize(candidate)
        let missing = testCase.preservedIdeas
            .filter { !hay.contains(normalize($0)) }
            .map { "dropped idea: “\($0)”" }
        return FidelityCheck(name: "idea count", violations: missing)
    }

    /// Check 2 — new-word diff: a word in the output that was not in the transcript
    /// must be a connective/article/punctuation, never a qualifier or hedge. Checked
    /// against the documented weighted insertions: a violation is one that appears in
    /// the candidate but not the transcript.
    static func newWordDiff(candidate: String, _ testCase: AcceptanceCase) -> FidelityCheck {
        let hay = normalize(candidate)
        let source = normalize(testCase.transcript)
        // Whole-word matching: `diretamente` must not fire on `indiretamente`.
        let violations = testCase.forbiddenInsertions
            .filter { containsWholeWord(hay, normalize($0)) && !containsWholeWord(source, normalize($0)) }
            .map { "inserted weighted word/downgrade: “\($0)”" }
        return FidelityCheck(name: "new-word diff", violations: violations)
    }

    /// Check 3 — modal check: every modal verb in the transcript survives with the
    /// same force. A lost modal (or a downgrade, caught as a forbidden insertion in
    /// check 2) is a violation.
    static func modalCheck(candidate: String, _ testCase: AcceptanceCase) -> FidelityCheck {
        let hay = normalize(candidate)
        let lost = testCase.survivingModals
            .filter { !hay.contains(normalize($0)) }
            .map { "lost modal force: “\($0)”" }
        return FidelityCheck(name: "modal check", violations: lost)
    }

    /// Check 4 — slip check: an ASR-noise span stays fumbled and marked. It must sit
    /// inside a `[? ... ?]` mark and no fluent repair of it may appear. This is the
    /// case-04 `se profissional` rule: a candidate that rewrites it fails regardless
    /// of the rest.
    static func slipCheck(candidate: String, _ testCase: AcceptanceCase) -> FidelityCheck {
        guard let noise = testCase.markedNoise else {
            return FidelityCheck(name: "slip check", violations: [])
        }
        var violations: [String] = []
        let marks = markedSpans(in: candidate).map(normalize)
        let span = normalize(noise.span)
        if !marks.contains(where: { $0.contains(span) }) {
            violations.append("ASR noise “\(noise.span)” is not kept inside a [? … ?] mark")
        }
        // Whole-word matching: the true utterance was `se é proporcional`, so a bare
        // `proporcional` means repair — but it must not fire on `desproporcional`,
        // which the transcript legitimately keeps.
        let hay = normalize(candidate)
        for repaired in noise.repairedForms where containsWholeWord(hay, normalize(repaired)) {
            violations.append("ASR noise repaired into “\(repaired)”")
        }
        return FidelityCheck(name: "slip check", violations: violations)
    }

    // MARK: - Internals

    /// Lowercase, strip backticks (so `` `/sync` `` matches `/sync`), and collapse all
    /// whitespace to single spaces, so matching is robust to formatting and line breaks.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "`", with: "")
        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whole-word containment: does the word sequence `needle` appear in `hay` on word
    /// boundaries? Splitting on non-letters means `proporcional` does not match inside
    /// `desproporcional`, and a multi-word needle (`não deve`) matches only as a run.
    static func containsWholeWord(_ hay: String, _ needle: String) -> Bool {
        let hayWords = words(hay)
        let needleWords = words(needle)
        guard !needleWords.isEmpty, needleWords.count <= hayWords.count else { return false }
        for start in 0...(hayWords.count - needleWords.count)
        where Array(hayWords[start..<start + needleWords.count]) == needleWords {
            return true
        }
        return false
    }

    /// Letter-only word tokens (accented letters kept; digits/punctuation are separators).
    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    /// The contents of every `[? ... ?]` mark in the text (the noise marker pass 2
    /// emits). Used by the slip check to prove a noise span is kept *within* a mark.
    static func markedSpans(in text: String) -> [String] {
        var spans: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[?"), let close = rest.range(of: "?]", range: open.upperBound..<rest.endIndex) {
            spans.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return spans
    }
}

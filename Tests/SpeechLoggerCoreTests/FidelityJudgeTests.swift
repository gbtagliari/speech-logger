import Foundation
import Testing

@testable import SpeechLoggerCore

/// The judge is the yardstick, so it is itself tested (issue #18). These run without
/// `claude`: synthetic candidates prove each of the four checks passes a faithful
/// rewrite and fails the documented failure mode it exists to catch. If the judge is
/// wrong, the whole acceptance suite is worthless.
struct FidelityJudgeTests {
    /// A case mirroring case 01/04's contract points, used across the checks.
    private let sample = AcceptanceCase(
        id: "sample",
        transcript: """
            a gente não pode fazer a correção para o Packers, a gente tem que fazer no branch \
            do bug fix, chamando o barra sync de uma maneira desproporcional
            """,
        preservedIdeas: ["Packers", "bug fix", "/sync"],
        survivingModals: ["não pode", "tem que"],
        forbiddenInsertions: ["não deve", "diretamente"],
        markedNoise: MarkedNoise(span: "se profissional", repairedForms: ["proporcional"]))

    // MARK: - A faithful candidate passes every check

    @Test("a faithful rewrite passes all four checks")
    func faithfulCandidatePasses() {
        let good = """
            A gente não pode fazer a correção para o Packers. A gente tem que fazer no branch \
            do bug fix, chamando o `/sync` de uma maneira desproporcional. E também \
            [? se profissional ?], inclusive.
            """
        let checks = FidelityJudge.judge(candidate: good, case: sample)
        let violations = checks.flatMap(\.violations)
        #expect(violations.isEmpty, "unexpected violations: \(violations)")
    }

    // MARK: - Idea count

    @Test("dropping a completed idea fails the idea-count check")
    func summarizingFailsIdeaCount() {
        // `/sync` and `bug fix` summarized away.
        let summarized = "A gente não pode fazer a correção para o Packers."
        let check = FidelityJudge.ideaCount(candidate: summarized, sample)
        #expect(!check.passed)
        #expect(check.violations.contains { $0.contains("/sync") })
    }

    @Test("a code-formatted endpoint still satisfies its idea anchor (backticks are ignored)")
    func backticksDoNotBreakAnchors() {
        let formatted = "chamando o `/sync`, no branch do bug fix, no Packers"
        #expect(FidelityJudge.ideaCount(candidate: formatted, sample).passed)
    }

    // MARK: - New-word diff

    @Test("inserting a semantic-weight word not in the transcript fails the new-word diff")
    func insertingWeightedWordFails() {
        let embellished = """
            A gente não pode fazer a correção diretamente para o Packers, tem que ser no \
            bug fix, no `/sync`, de maneira desproporcional. [? se profissional ?]
            """
        let check = FidelityJudge.newWordDiff(candidate: embellished, sample)
        #expect(!check.passed)
        #expect(check.violations.contains { $0.contains("diretamente") })
    }

    @Test("a downgraded modal (`não pode` -> `não deve`) fails the new-word diff")
    func modalDowngradeFails() {
        let downgraded = "A correção não deve ser feita no Packers, no bug fix, no `/sync`."
        let check = FidelityJudge.newWordDiff(candidate: downgraded, sample)
        #expect(!check.passed)
        #expect(check.violations.contains { $0.contains("não deve") })
    }

    // MARK: - Modal check

    @Test("losing a modal entirely fails the modal check")
    func losingModalFails() {
        // `não pode` gone (turned into a bare assertion).
        let flattened = "A correção é feita no bug fix, no Packers, no `/sync`. A gente tem que fazer isso."
        let check = FidelityJudge.modalCheck(candidate: flattened, sample)
        #expect(!check.passed)
        #expect(check.violations.contains { $0.contains("não pode") })
    }

    // MARK: - Slip check

    @Test("keeping the noise span inside a [? … ?] mark passes the slip check")
    func markedNoisePasses() {
        let marked = "tudo certo, e também [? se profissional ?], inclusive"
        #expect(FidelityJudge.slipCheck(candidate: marked, sample).passed)
    }

    @Test("repairing the noise into a fluent word fails the slip check")
    func repairedNoiseFails() {
        // The model guessed `se é proporcional` — the exact forbidden repair.
        let repaired = "tudo certo, e também se é proporcional, inclusive"
        let check = FidelityJudge.slipCheck(candidate: repaired, sample)
        #expect(!check.passed)
    }

    @Test("dropping the mark (noise silently removed) fails the slip check")
    func unmarkedNoiseFails() {
        let dropped = "tudo certo, inclusive com outros endpoints"
        let check = FidelityJudge.slipCheck(candidate: dropped, sample)
        #expect(!check.passed)
        #expect(check.violations.contains { $0.contains("not kept inside") })
    }

    @Test("`desproporcional` in the output does not false-trigger the `proporcional` repair check")
    func desproporcionalIsNotARepair() {
        // The legitimate word `desproporcional` contains `proporcional` as a substring;
        // whole-word matching must not read it as a repair.
        let legit = "chamando de uma maneira desproporcional, e também [? se profissional ?]"
        #expect(FidelityJudge.slipCheck(candidate: legit, sample).passed)
    }

    // MARK: - Role collapse

    /// The failure mode that actually shows up in live sampling: instead of
    /// transforming the dictation, the model answers it as if it were a chat message
    /// to an assistant, summarizing the content and offering to act on it. The
    /// candidate below is a hand-written miniature of that shape.
    ///
    /// The judge has no "is this a chat reply?" check and does not need one: a reply
    /// necessarily drops the speaker's ideas and modal force, so the existing checks
    /// catch it. This test pins that, so a future loosening of idea count or modal
    /// check cannot quietly let role collapse through.
    @Test("a chat reply instead of a rewrite fails on ideas and modal force")
    func roleCollapseIsCaught() {
        let reply = """
            Entendi a explicação sobre o fluxo de merge. Resumo da regra: a correção do \
            conflito não deve ser feita ali, e sim na origem da mudança. Quer que eu \
            documente isso em um guia de contribuição? Me diga e eu sigo.
            """
        let checks = FidelityJudge.judge(candidate: reply, case: sample)
        let failed = Set(checks.filter { !$0.passed }.map(\.name))

        #expect(failed.contains("idea count"))  // "Packers", "bug fix", "/sync" gone
        #expect(failed.contains("modal check"))  // "não pode" / "tem que" gone
        #expect(failed.contains("new-word diff"))  // "não deve" is a downgrade
    }

    // MARK: - Whole-word matching

    @Test("whole-word matching does not fire a word inside a larger word")
    func wholeWordDoesNotMatchSubstring() {
        #expect(!FidelityJudge.containsWholeWord("uma maneira desproporcional", "proporcional"))
        #expect(FidelityJudge.containsWholeWord("é se proporcional agora", "proporcional"))
        #expect(FidelityJudge.containsWholeWord("a correção não deve ser feita", "não deve"))
        #expect(!FidelityJudge.containsWholeWord("a gente não pode fazer", "não deve"))
    }
}

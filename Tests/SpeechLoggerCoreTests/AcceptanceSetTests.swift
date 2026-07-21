import Foundation
import Testing

@testable import SpeechLoggerCore

/// The product's regression suite (issue #18): the four acceptance-set cases run
/// through the **real** two-pass pipeline, each judged by the four fidelity checks
/// (idea count, new-word diff, modal check, slip check). It is developer-run and
/// offline — gated on `claude` + credentials + the recorded transcripts, so it never
/// fails on a machine without the toolchain. This is where
/// prompt drift is caught: if a prompt edit makes a model summarize, insert a weighted
/// word, downgrade a modal, or repair `se profissional`, a case here goes red.
struct AcceptanceSetTests {
    @Test(
        "each acceptance case survives the real two-pass pipeline against the fidelity contract",
        .enabled(if: AcceptanceFixtures.organizationAvailable),
        arguments: AcceptanceFixtures.cases)
    func acceptanceCasePassesTheContract(_ testCase: AcceptanceCase) async throws {
        let organizer = try AcceptanceFixtures.organizer()

        // The real product: pass 1 annotates, pass 2 rewrites. Judge pass-2 output.
        let (_, final) = try await organizer.organize(testCase.transcript)

        let checks = FidelityJudge.judge(candidate: final, case: testCase)
        for check in checks {
            #expect(
                check.passed,
                "\(testCase.id) failed the \(check.name) check: \(check.violations.joined(separator: "; "))\n---\n\(final)")
        }
    }

    /// The headline non-negotiable, isolated so a regression here is unmistakable
    /// (issue #18 acceptance criterion): case 04's `se profissional` is ASR noise the
    /// tool must **mark**, never repair. A candidate that rewrites it fails regardless
    /// of how good the rest of the output is.
    @Test(
        "case 04: `se profissional` is marked [? … ?], never repaired",
        .enabled(if: AcceptanceFixtures.organizationAvailable))
    func caso04MarksNoiseNeverRepairs() async throws {
        let testCase = try #require(AcceptanceFixtures.cases.first { $0.id == "caso-04" })
        let organizer = try AcceptanceFixtures.organizer()

        let (_, final) = try await organizer.organize(testCase.transcript)

        let slip = FidelityJudge.slipCheck(candidate: final, testCase)
        #expect(slip.passed, "case 04 must mark, not repair: \(slip.violations.joined(separator: "; "))\n---\n\(final)")
    }
}

import Foundation
import SpeechLoggerCore

/// The acceptance set (issue #18): the four cases and their fidelity-contract
/// expectations, plus the toolchain gate the drift check needs.
///
/// This used to be a test fixture. It is not a test: judging it requires the **real**
/// two-pass pipeline, so every run makes billed `claude` calls and its verdict is
/// nondeterministic by construction (the input is a model). It now backs the
/// developer-run `DriftCheck` tool instead, where a *rate over N samples* is reported
/// rather than a single pass/fail that a coin flip decides.
enum AcceptanceCases {
    /// The drift check runs the real pipeline, so it needs `claude`, live credentials,
    /// and the three recorded transcripts. Absent any of them it refuses to run rather
    /// than reporting a meaningless zero.
    static var available: Bool { unavailableReason == nil }

    /// Why the check cannot run, for an actionable message instead of a silent skip
    /// (the trap the old test-gated version fell into: it passed by running nothing).
    static var unavailableReason: String? {
        if !FileManager.default.fileExists(atPath: ToolchainPaths.defaults.claude) {
            return "claude not found at \(ToolchainPaths.defaults.claude)"
        }
        if !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/.credentials.json") {
            return "not logged in: no ~/.claude/.credentials.json"
        }
        let missing = ["02", "03", "04"].filter {
            !FileManager.default.fileExists(atPath: transcriptURL(case: $0).path)
        }
        guard missing.isEmpty else {
            return "missing transcripts in .scratch/: " + missing.map { "caso-\($0)" }.joined(separator: ", ")
        }
        return nil
    }

    /// The `mlx_whisper` transcript of a recorded case, in `.scratch/`.
    static func transcriptURL(case id: String) -> URL {
        URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".scratch/dictation-tool/samples/caso-\(id).txt")
    }

    /// A real organizer wired with the committed prompts.
    ///
    /// The prompts are read from the source tree rather than via `Prompts.bundled()`:
    /// this is a developer tool run from the repo, so reading the committed files is
    /// simpler than resolving a framework resource bundle from a command-line tool,
    /// and it measures exactly the text that is under version control.
    static func organizer() throws -> ClaudeOrganizer {
        ClaudeOrganizer(prompts: Prompts(pass1: try prompt("pass1"), pass2: try prompt("pass2")))
    }

    private static func prompt(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: repoRoot)
                .appendingPathComponent("Sources/SpeechLoggerCore/Resources/\(name).txt"),
            encoding: .utf8)
    }

    /// The four acceptance cases. Each case's `forbiddenInsertions` is unioned with
    /// `sharedForbiddenInsertions`, so the new-word-diff check has teeth on every
    /// case, not only the typed case 01.
    static var cases: [AcceptanceCase] { [caso01, caso02, caso03, caso04].map(withSharedForbidden) }

    /// The semantically-weighted words the fidelity contract names as forbidden
    /// insertions (`.scratch/dictation-tool/assets/fidelity-contract.md`, "Forbidden":
    /// "words that qualify, hedge, intensify or scope"). A word a case legitimately
    /// spoke is excluded automatically by the "not in source" clause (e.g. `apenas` in
    /// case 04's `deveria ter apenas mil`), so this never false-fails.
    static let sharedForbiddenInsertions = [
        "diretamente", "apenas", "provavelmente", "correspondente",
        "basicamente", "simplesmente", "obviamente", "claramente",
    ]

    // MARK: - The cases (expectations from acceptance-set.md, made checkable)

    /// Case 01 — merge conflicts in the Packers branch (typed). The ChatGPT workflow
    /// downgraded `não pode` → `não deve` and inserted `diretamente` / `correspondente`.
    private static let caso01 = AcceptanceCase(
        id: "caso-01",
        transcript: """
            Quando a gente está fazendo o merge da desenv dentro do branch do Packers, podem \
            acontecer alguns conflitos. E normalmente é importante a gente verificar se esses \
            conflitos foram introduzidos por alguma feature que está em desenvolvimento e que \
            está presente somente dentro do branch do Packers. Nesses casos, quando a gente vê \
            que o conflito ele é originado por algum código que veio da master ou que veio da \
            desenv para dentro do branch do Packers e está lá porque está dentro de um feature \
            branch, um bug fix ou alguma coisa assim, que ainda não foi mergeado para dentro da \
            desenv, a gente não pode fazer a correção para o Packers. A gente tem que fazer essa \
            correção para o branch da feature do bug fix.
            """,
        preservedIdeas: ["desenv", "master", "bug fix", "Packers"],
        survivingModals: ["não pode", "tem que"],
        forbiddenInsertions: ["não deve", "diretamente", "correspondente"],
        markedNoise: nil)

    /// Case 02 — alinhar com o time. `acho que` (a hedge, twice) is modal force and
    /// must survive; a model that "tightens" it into an assertion fails.
    private static let caso02 = AcceptanceCase(
        id: "caso-02",
        transcript: transcript("02"),
        preservedIdeas: ["Packers", "daily"],
        survivingModals: ["acho que", "tem que"],
        forbiddenInsertions: [],
        markedNoise: nil)

    /// Case 03 — build vs buy. The hardest slip: `ele gera o whisper` is sloppy but
    /// plausible speech and must survive unrepaired; product names get capitalized.
    private static let caso03 = AcceptanceCase(
        id: "caso-03",
        transcript: transcript("03"),
        preservedIdeas: ["ChatGPT", "Whisper", "ele gera o whisper", "fluxo que hoje eu uso"],
        survivingModals: [],
        forbiddenInsertions: [],
        markedNoise: nil)

    /// Case 04 — the `/sync` push storm. `se profissional` (ASR for `se é proporcional`)
    /// must be marked, never repaired; endpoints get code-formatted; numbers survive.
    private static let caso04 = AcceptanceCase(
        id: "caso-04",
        transcript: transcript("04"),
        preservedIdeas: ["/sync", "/home", "/timeline", "eBurn", "sete mil"],
        survivingModals: ["deveria"],
        forbiddenInsertions: [],
        markedNoise: MarkedNoise(span: "se profissional", repairedForms: ["proporcional"]))

    // MARK: - Internals

    /// Union the shared contract-forbidden words into a case's own list (deduped).
    private static func withSharedForbidden(_ acceptanceCase: AcceptanceCase) -> AcceptanceCase {
        var merged = acceptanceCase.forbiddenInsertions
        for word in sharedForbiddenInsertions where !merged.contains(word) { merged.append(word) }
        return AcceptanceCase(
            id: acceptanceCase.id,
            transcript: acceptanceCase.transcript,
            preservedIdeas: acceptanceCase.preservedIdeas,
            survivingModals: acceptanceCase.survivingModals,
            forbiddenInsertions: merged,
            markedNoise: acceptanceCase.markedNoise)
    }

    /// Read a recorded transcript, or "" if absent (the tool refuses to run when the
    /// gate is unmet, so an empty transcript never reaches the pipeline).
    private static func transcript(_ id: String) -> String {
        (try? String(contentsOf: transcriptURL(case: id), encoding: .utf8)) ?? ""
    }

    /// Anchored to this source file, not the process cwd: three parents up from
    /// `Sources/DriftCheck/ThisFile.swift` is the repo root that holds `.scratch/`.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .path
}

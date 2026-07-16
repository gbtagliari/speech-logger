import Foundation
import SpeechLoggerCore

/// The acceptance set as test fixtures: the four cases, their transcripts, and the
/// gate for the developer-run harness (issue #18, SPEC "Testing Decisions"). The
/// recordings and their transcripts live in `.scratch/` (gitignored — personal
/// audio), so the harness is guarded on their presence, exactly like the #17
/// transcription end-to-end tests. Case 01 is typed, so its transcript is inline.
enum AcceptanceFixtures {
    /// The harness runs the real two-pass pipeline, so it needs `claude`, live
    /// credentials, and the three recorded transcripts. Absent any of them, the
    /// harness is skipped (never a false failure on a machine without the toolchain).
    static let organizationAvailable: Bool =
        FileManager.default.fileExists(atPath: ToolchainPaths.defaults.claude)
        && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/.credentials.json")
        && ["02", "03", "04"].allSatisfy {
            FileManager.default.fileExists(atPath: transcriptURL(case: $0).path)
        }

    /// The `mlx_whisper` transcript of a recorded case, in `.scratch/`.
    static func transcriptURL(case id: String) -> URL {
        URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".scratch/dictation-tool/samples/caso-\(id).txt")
    }

    /// A real organizer wired with the bundled prompts.
    static func organizer() throws -> ClaudeOrganizer {
        ClaudeOrganizer(prompts: try Prompts.bundled())
    }

    /// The four acceptance cases. Transcripts for the recorded cases are read from
    /// `.scratch/`; if absent, the field is empty and the harness is skipped anyway.
    /// Each case's `forbiddenInsertions` is unioned with `sharedForbiddenInsertions`,
    /// so the new-word-diff check has teeth on every case, not only the typed case 01.
    static let cases: [AcceptanceCase] = [caso01, caso02, caso03, caso04].map(withSharedForbidden)

    /// The semantically-weighted words the fidelity contract names as forbidden
    /// insertions (`.scratch/dictation-tool/assets/fidelity-contract.md`, "Forbidden":
    /// "words that qualify, hedge, intensify or scope"). The new-word diff flags any of
    /// these that appears in the output but *not* the transcript — so it fires on a
    /// real recorded case too, not just case 01's documented ChatGPT edits. A word a
    /// case legitimately spoke is excluded automatically by the "not in source" clause
    /// (e.g. `apenas` in case 04's `deveria ter apenas mil`), so this never false-fails.
    static let sharedForbiddenInsertions = [
        "diretamente", "apenas", "provavelmente", "correspondente",
        "basicamente", "simplesmente", "obviamente", "claramente",
    ]

    // MARK: - The cases (expectations from acceptance-set.md, made testable)

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
    private static func withSharedForbidden(_ testCase: AcceptanceCase) -> AcceptanceCase {
        var merged = testCase.forbiddenInsertions
        for word in sharedForbiddenInsertions where !merged.contains(word) { merged.append(word) }
        return AcceptanceCase(
            id: testCase.id,
            transcript: testCase.transcript,
            preservedIdeas: testCase.preservedIdeas,
            survivingModals: testCase.survivingModals,
            forbiddenInsertions: merged,
            markedNoise: testCase.markedNoise)
    }

    /// Read a recorded transcript, or "" if absent (the harness is gated on presence,
    /// so an empty transcript never actually reaches the pipeline).
    private static func transcript(_ id: String) -> String {
        (try? String(contentsOf: transcriptURL(case: id), encoding: .utf8)) ?? ""
    }

    /// Anchored to this source file, not the process cwd (`xcodebuild` sets it to
    /// DerivedData): three parents up from `Tests/SpeechLoggerCoreTests/ThisFile.swift`
    /// is the repo root that holds `.scratch/`.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .path
}

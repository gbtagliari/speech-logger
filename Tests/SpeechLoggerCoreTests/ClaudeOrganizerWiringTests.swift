import Foundation
import Testing

@testable import SpeechLoggerCore

/// The organizer's *wiring*, offline. `OrganizerTests` proves the pure pieces (argv,
/// scrubbed environment, `outcome` gating) in isolation; this suite proves they are
/// actually joined up — that `annotate` sends the pass-1 prompt and `rewrite` the
/// pass-2 one, that the transcript rides on stdin and never in argv, that each pass
/// tags its own `Stage` on failure, and that the stderr tail is capped.
///
/// Every case runs the real `ClaudeOrganizer` against a canned `SubprocessRunning`,
/// so the whole `claude` output matrix (success, cli error, non-zero exit, empty
/// result, non-JSON, unlaunchable binary) is covered with no binary, no network and
/// no billed call.
struct ClaudeOrganizerWiringTests {
    // MARK: - Success

    @Test("a clean success returns the trimmed result text, on both passes")
    func successReturnsTrimmedText() async throws {
        let fake = FakeClaude(.success("  texto final\n"))
        let organizer = makeOrganizer(fake)

        #expect(try await organizer.annotate("fala") == "texto final")
        #expect(try await organizer.rewrite("anotado") == "texto final")
    }

    @Test("annotate sends the pass-1 prompt, rewrite the pass-2 one")
    func eachPassSendsItsOwnPrompt() async throws {
        let fake = FakeClaude(.success("ok"))
        let organizer = makeOrganizer(fake)

        _ = try await organizer.annotate("fala")
        _ = try await organizer.rewrite("anotado")

        let calls = await fake.calls
        #expect(try #require(calls.first).systemPrompt == "PROMPT-1")
        #expect(try #require(calls.last).systemPrompt == "PROMPT-2")
    }

    @Test("the transcript goes on stdin and never into argv — out of `ps`, into the cache")
    func transcriptRidesOnStdinOnly() async throws {
        let fake = FakeClaude(.success("ok"))
        let organizer = makeOrganizer(fake)
        let secret = "minha fala privada sobre o cliente"

        _ = try await organizer.annotate(secret)

        let call = try #require(await fake.calls.first)
        #expect(call.stdin.contains(secret))
        #expect(!call.arguments.contains { $0.contains(secret) })
        #expect(call.executable == "/fake/claude")
    }

    /// The delimiter is what keeps a *clean* dictation from reading as a request
    /// addressed to the model (~49% role collapse without it; see `delimited`).
    @Test("each pass wraps its input in its own delimiter before sending it")
    func inputIsDelimitedPerPass() async throws {
        let fake = FakeClaude(.success("ok"))
        let organizer = makeOrganizer(fake)

        _ = try await organizer.annotate("minha fala")
        _ = try await organizer.rewrite("texto marcado")

        let calls = await fake.calls
        #expect(try #require(calls.first).stdin == "<transcricao>\nminha fala\n</transcricao>")
        #expect(try #require(calls.last).stdin == "<texto_anotado>\ntexto marcado\n</texto_anotado>")
    }

    @Test("the two passes never share a delimiter — each names the artifact it receives")
    func passesUseDistinctTags() {
        #expect(ClaudeOrganizer.InputTag.transcript != ClaudeOrganizer.InputTag.annotated)
        #expect(ClaudeOrganizer.delimited("x", tag: "t") == "<t>\nx\n</t>")
    }

    @Test("the subprocess environment is scrubbed to the four auth variables")
    func environmentReachesTheSubprocessScrubbed() async throws {
        let fake = FakeClaude(.success("ok"))
        _ = try await makeOrganizer(fake).annotate("fala")

        let env = try #require(await fake.calls.first).environment
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(Set(env.keys).isSubset(of: ["HOME", "USER", "PATH", "TMPDIR"]))
    }

    // MARK: - The failure matrix, per pass

    /// `is_error` is the gate. `subtype` reads `"success"` on every error, and the
    /// exit code can be 0, so neither is trusted.
    @Test("a cli error fails with the stage of the pass that made the call", arguments: [Stage.pass1, .pass2])
    func cliErrorCarriesItsOwnStage(stage: Stage) async throws {
        let fake = FakeClaude(.raw(
            rc: 0,
            stdout: #"{"is_error": true, "subtype": "success", "result": "Not logged in"}"#))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: stage))

        #expect(error.stage == stage)
        #expect(error.reason == .cliError)
        #expect(error.detail.contains("Not logged in"))
    }

    @Test("a non-zero exit fails even when the JSON looks clean", arguments: [Stage.pass1, .pass2])
    func nonZeroExitFails(stage: Stage) async throws {
        let fake = FakeClaude(.raw(rc: 1, stdout: #"{"is_error": false, "result": "texto"}"#))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: stage))

        #expect(error.stage == stage)
        #expect(error.reason == .cliError)
    }

    @Test("an empty result is empty_output, distinct from a cli error", arguments: [Stage.pass1, .pass2])
    func emptyResultIsEmptyOutput(stage: Stage) async throws {
        let fake = FakeClaude(.raw(rc: 0, stdout: #"{"is_error": false, "result": "   \n "}"#))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: stage))

        #expect(error.stage == stage)
        #expect(error.reason == .emptyOutput)
    }

    /// The `--output-format text` hazard: error prose lands on stdout where the
    /// rewritten text belongs. It must never be parsed as content.
    @Test("non-JSON stdout is a cli error, never returned as text", arguments: [Stage.pass1, .pass2])
    func nonJSONStdoutIsCliError(stage: Stage) async throws {
        let fake = FakeClaude(.raw(rc: 1, stdout: "There's an issue with the selected model"))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: stage))

        #expect(error.reason == .cliError)
    }

    @Test("an unlaunchable binary is missing_binary, not a false success", arguments: [Stage.pass1, .pass2])
    func unlaunchableBinaryIsMissingBinary(stage: Stage) async throws {
        let fake = FakeClaude(.launchFailure("No such file or directory"))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: stage))

        #expect(error.stage == stage)
        #expect(error.reason == .missingBinary)
    }

    @Test("a runaway stderr is capped before it can bloat meta.json")
    func stderrTailIsCapped() async throws {
        // Non-JSON stdout with an empty result, so `detail` falls back to stderr.
        let fake = FakeClaude(.raw(
            rc: 1, stdout: "not json", stderr: String(repeating: "x", count: 10_000)))
        let error = try #require(await captureFailure(makeOrganizer(fake), stage: .pass1))

        #expect(error.detail.count <= 2000)
    }

    // MARK: - Helpers

    private func makeOrganizer(_ runner: FakeClaude) -> ClaudeOrganizer {
        ClaudeOrganizer(
            claude: "/fake/claude",
            prompts: Prompts(pass1: "PROMPT-1", pass2: "PROMPT-2"),
            runner: runner)
    }

    /// Drive the pass named by `stage` and return the failure it threw, so each
    /// matrix case asserts identically against both passes. `nil` means the pass
    /// unexpectedly succeeded, which `#require` at the call site turns into a failure.
    private func captureFailure(
        _ organizer: ClaudeOrganizer, stage: Stage
    ) async -> (stage: Stage, reason: FailureReason, detail: String)? {
        do {
            _ = stage == .pass1
                ? try await organizer.annotate("fala")
                : try await organizer.rewrite("anotado")
            return nil
        } catch {
            // Typed throws: `error` is an `OrganizationError`.
            guard case .failed(let stage, let reason, let detail) = error else { return nil }
            return (stage, reason, detail)
        }
    }
}

// MARK: - The canned `claude`

/// What a canned `claude` invocation produces.
private enum CannedRun: Sendable {
    /// A well-formed success envelope carrying `result`.
    case success(String)
    /// A raw process result, for the malformed and error-envelope cases.
    case raw(rc: Int32, stdout: String, stderr: String = "")
    /// The process could not be launched at all (binary absent or not executable).
    case launchFailure(String)
}

/// A `claude` that never runs: it returns a canned result and records how it was
/// called, so the organizer's wiring can be asserted without a billed invocation.
private actor FakeClaude: SubprocessRunning {
    /// One recorded invocation, with the system prompt lifted out of argv.
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let stdin: String

        /// The value passed to `--system-prompt`, the only per-pass difference in argv.
        var systemPrompt: String? {
            guard let i = arguments.firstIndex(of: "--system-prompt"), i + 1 < arguments.count
            else { return nil }
            return arguments[i + 1]
        }
    }

    private let canned: CannedRun
    private(set) var calls: [Call] = []

    init(_ canned: CannedRun) {
        self.canned = canned
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Data?
    ) async throws(SubprocessLaunchError) -> SubprocessResult {
        calls.append(Call(
            executable: executable, arguments: arguments, environment: environment,
            stdin: String(decoding: stdin ?? Data(), as: UTF8.self)))

        switch canned {
        case .success(let text):
            // `subtype` is deliberately "success" throughout: the gate reads
            // `is_error`, never this field, which lies "success" on errors too.
            let envelope = try? JSONSerialization.data(withJSONObject: [
                "is_error": false, "subtype": "success", "result": text,
            ])
            return SubprocessResult(
                terminationStatus: 0, stdout: envelope ?? Data(), stderr: Data())
        case .raw(let rc, let stdout, let stderr):
            return SubprocessResult(
                terminationStatus: rc, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        case .launchFailure(let message):
            throw SubprocessLaunchError(message: message)
        }
    }
}

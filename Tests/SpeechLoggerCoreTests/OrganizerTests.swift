import Foundation
import Testing

@testable import SpeechLoggerCore

/// The `claude` shell-out contract (ADR-0001, ADR-0002, issue #18): the argv pins the
/// full model id and every load-bearing flag (`--effort low`, `--safe-mode`,
/// `--output-format json`), the environment is scrubbed to the four variables auth
/// needs, and failure is gated on `is_error` — never `subtype`, which lies `"success"`
/// on every error. The argv/env tests catch a dropped flag; the `outcome` tests prove
/// the gating logic against synthetic JSON, no binary required.
struct OrganizerTests {
    // MARK: - Pinned argv

    @Test("the argv pins the full model id — never the re-pointing `sonnet` alias")
    func argvPinsModel() {
        let argv = ClaudeOrganizer.arguments(systemPrompt: "SYS")
        #expect(adjacent(argv, "--model", "claude-sonnet-5"))
        #expect(ClaudeOrganizer.model == "claude-sonnet-5")
    }

    @Test("the argv pins the load-bearing flags — effort low, safe-mode, json, empty tools")
    func argvPinsLoadBearingFlags() {
        let argv = ClaudeOrganizer.arguments(systemPrompt: "SYS")
        #expect(adjacent(argv, "--effort", "low"))  // the single most important flag
        #expect(adjacent(argv, "--output-format", "json"))  // the only safe failure signal
        #expect(adjacent(argv, "--tools", ""))  // pure text transform
        #expect(adjacent(argv, "--system-prompt", "SYS"))
        #expect(argv.contains("--safe-mode"))  // no CLAUDE.md / MEMORY.md leakage
        #expect(argv.contains("--no-session-persistence"))
        #expect(argv.contains("--print"))
    }

    @Test("the transcript is never in the argv — it goes on stdin, out of `ps` and into the cache")
    func argvHasNoTranscript() {
        let argv = ClaudeOrganizer.arguments(systemPrompt: "SYS")
        // Only the prompt rides in argv; the private dictation must not.
        #expect(!argv.contains { $0.contains("TRANSCRIPT_MARKER") })
        #expect(argv.filter { $0 == "SYS" }.count == 1)
    }

    // MARK: - Environment

    @Test("the environment keeps only HOME/USER/PATH/TMPDIR — HOME is load-bearing for auth")
    func environmentIsScrubbedButKeepsHome() {
        let env = ClaudeOrganizer.environment(base: [
            "HOME": "/Users/x", "USER": "x", "PATH": "/usr/bin", "TMPDIR": "/tmp",
            "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "leak", "SECRET": "nope",
        ])
        #expect(env["HOME"] == "/Users/x")  // else `claude` fails "Not logged in"
        #expect(env["USER"] == "x")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["TMPDIR"] == "/tmp")
        // Nothing else leaks into the call.
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["SECRET"] == nil)
    }

    @Test("a missing variable is simply absent, never an empty string")
    func environmentOmitsMissingKeys() {
        let env = ClaudeOrganizer.environment(base: ["HOME": "/Users/x"])
        #expect(env["HOME"] == "/Users/x")
        #expect(env.keys.sorted() == ["HOME"])
    }

    // MARK: - Failure gating (`outcome`)

    @Test("a clean success returns the trimmed result text")
    func outcomeSuccess() {
        let json = #"{"is_error": false, "subtype": "success", "result": "  texto final\n"}"#
        let result = ClaudeOrganizer.outcome(rc: 0, stdout: Data(json.utf8), stderr: "", stage: .pass2)
        #expect(result == .success("texto final"))
    }

    @Test(
        "is_error true is a cli_error even when rc and subtype say success — subtype is the liar",
        arguments: [
            // Not logged in / network error: is_error true, api_error_status null.
            #"{"is_error": true, "subtype": "success", "result": "Not logged in · Please run /login"}"#,
            // Bad model: is_error true, English error prose in `result`.
            #"{"is_error": true, "subtype": "success", "result": "There's an issue with the selected model"}"#,
        ])
    func outcomeIsErrorIsFailure(json: String) {
        // rc is deliberately 0 here: the gate must fire on is_error, not the exit code.
        let result = ClaudeOrganizer.outcome(rc: 0, stdout: Data(json.utf8), stderr: "", stage: .pass1)
        guard case .failure(.failed(let stage, let reason, let detail)) = result else {
            Issue.record("expected a cli_error failure, got \(result)")
            return
        }
        #expect(stage == .pass1)
        #expect(reason == .cliError)
        #expect(!detail.isEmpty)  // the CLI's error prose rides along for the log
    }

    @Test("a non-zero exit is a failure even if the JSON looks clean")
    func outcomeNonZeroExitIsFailure() {
        let json = #"{"is_error": false, "result": "text"}"#
        let result = ClaudeOrganizer.outcome(rc: 1, stdout: Data(json.utf8), stderr: "boom", stage: .pass2)
        guard case .failure(.failed(_, let reason, _)) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(reason == .cliError)
    }

    @Test("an empty result is empty_output, distinct from a cli_error")
    func outcomeEmptyResultIsEmptyOutput() {
        let json = #"{"is_error": false, "result": "   \n  "}"#
        let result = ClaudeOrganizer.outcome(rc: 0, stdout: Data(json.utf8), stderr: "", stage: .pass1)
        guard case .failure(.failed(let stage, let reason, _)) = result else {
            Issue.record("expected empty_output, got \(result)")
            return
        }
        #expect(stage == .pass1)
        #expect(reason == .emptyOutput)
    }

    @Test("non-JSON stdout (empty stdin, `text` output) is a cli_error, never parsed as content")
    func outcomeNonJsonIsFailure() {
        // With `--output-format text` a failing run prints English prose to stdout.
        let result = ClaudeOrganizer.outcome(
            rc: 1, stdout: Data("There's an issue with the selected model".utf8),
            stderr: "", stage: .pass2)
        guard case .failure(.failed(_, let reason, let detail)) = result else {
            Issue.record("expected a cli_error, got \(result)")
            return
        }
        #expect(reason == .cliError)
        #expect(!detail.isEmpty)
    }

    @Test("a JSON object with no is_error field is treated as an error, never a false success")
    func outcomeMissingIsErrorIsFailure() {
        let json = #"{"result": "text", "subtype": "success"}"#
        let result = ClaudeOrganizer.outcome(rc: 0, stdout: Data(json.utf8), stderr: "", stage: .pass1)
        guard case .failure = result else {
            Issue.record("expected a failure when is_error is absent, got \(result)")
            return
        }
    }

    // MARK: - Missing binary

    @Test("a missing claude binary surfaces as missing_binary, not a false success")
    func missingBinaryFails() async {
        let organizer = ClaudeOrganizer(
            claude: "/nonexistent/claude", prompts: Prompts(pass1: "p1", pass2: "p2"))
        do {
            _ = try await organizer.annotate("qualquer coisa")
            Issue.record("expected missing_binary, but annotate succeeded")
        } catch {
            // Typed throws: `error` is an `OrganizationError`.
            guard case .failed(let stage, let reason, _) = error else { return }
            #expect(stage == .pass1)
            #expect(reason == .missingBinary)
        }
    }

    // MARK: - Helpers

    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return false }
        return argv[index + 1] == value
    }
}

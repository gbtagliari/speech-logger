import Foundation

/// Why an organization pass failed. Structural only — the app never judges the
/// fidelity contract at runtime; fluent-but-wrong output flows through to
/// `organized` and the offline acceptance set catches drift. The
/// `stage` (`pass1`/`pass2`) and `reason` map straight onto `ItemStore.fail`.
public enum OrganizationError: Error, Equatable {
    case failed(stage: Stage, reason: FailureReason, detail: String)
}

/// The organization seam: the two LLM passes as pure functions of text
/// (`(transcript, prompt) → text`), the highest-value seam in the pipeline. Split into
/// the two passes so the lane can persist the annotated pass-1 pivot (`pass1.txt`)
/// between them — retaining it even when
/// pass 2 fails, which is what makes the two-pass contract auditable (ADR-0001).
public protocol Organizing: Sendable {
    /// Pass 1 — annotate. Marks false starts, repetitions, superseded corrections,
    /// and ASR noise; rewrites nothing. Throws with `stage: .pass1`.
    func annotate(_ transcript: String) async throws(OrganizationError) -> String
    /// Pass 2 — rewrite. Applies the marks mechanically, then cleans up. Its output
    /// is the final copyable text. Throws with `stage: .pass2`.
    func rewrite(_ annotated: String) async throws(OrganizationError) -> String
}

extension Organizing {
    /// Run both passes end to end, returning the annotated pivot and the final text.
    /// A convenience over `annotate` + `rewrite` for callers that want the whole
    /// transform in one call (the acceptance harness); the lane calls the two passes
    /// separately so it can persist `pass1.txt` in between.
    public func organize(_ transcript: String) async throws(OrganizationError) -> (pass1: String, final: String) {
        let pass1 = try await annotate(transcript)
        let final = try await rewrite(pass1)
        return (pass1, final)
    }
}

/// Organizes a transcript into final text by two `claude` calls (ADR-0001), the
/// unbounded-parallel lane's per-item worker (ADR-0006). Both passes are the same
/// pinned invocation; only the system prompt and the input differ. Every flag is
/// load-bearing (`docs/research/claude-cli-shell-out-contract.md`):
///
///   - `--effort low` — unset, the CLI thinks its way through a mechanical task at
///     ~10× the latency and cost, with wild run-to-run nondeterminism. Mandatory.
///   - `--safe-mode` — else `CLAUDE.md`/`MEMORY.md` leak into every transcription run.
///   - `--output-format json` — the *only* safe failure signal. With `text`, an
///     error message prints to stdout where the rewritten text belongs.
///
/// Failure is gated on **`is_error`** (and a non-zero exit), never `subtype` (which
/// reads `"success"` in every error case). The full model id is pinned so a new
/// Sonnet cannot silently re-point the behaviour the prompts were calibrated against.
public struct ClaudeOrganizer: Organizing {
    private let claude: String
    private let pass1Prompt: String
    private let pass2Prompt: String
    /// The subprocess seam (`SubprocessRunning`). Production gets the live runner;
    /// tests inject canned results so the wiring is covered without a billed call.
    private let runner: any SubprocessRunning

    /// The pinned model. The full id, never the `sonnet` alias (which re-points on
    /// the next Sonnet release). There is no fallback model — only retry.
    public static let model = "claude-sonnet-5"

    /// - Parameters:
    ///   - claude: absolute path to `claude` (not on a GUI app's `PATH`).
    ///   - prompts: the two system prompts. Production loads them from the bundle
    ///     via `Prompts.bundled()`; tests inject strings.
    public init(claude: String = ToolchainPaths.defaults.claude, prompts: Prompts) {
        self.init(claude: claude, prompts: prompts, runner: LiveSubprocessRunner())
    }

    /// Injects the subprocess seam. Internal so the public API stays a two-argument
    /// init; tests reach it through `@testable import`.
    init(
        claude: String = ToolchainPaths.defaults.claude,
        prompts: Prompts,
        runner: any SubprocessRunning
    ) {
        self.claude = claude
        self.pass1Prompt = prompts.pass1
        self.pass2Prompt = prompts.pass2
        self.runner = runner
    }

    /// The pinned `claude` argv for one pass. Built as an array (never a shell
    /// string). The transcript is *not* here — it goes on stdin, keeping the private
    /// speech out of `argv` (visible to `ps`) and letting the prompt be cached.
    public static func arguments(systemPrompt: String) -> [String] {
        [
            "--print",
            "--model", model,
            "--effort", "low",  // the single most important flag; see the contract doc
            "--system-prompt", systemPrompt,
            "--tools", "",  // pure text transform: nothing reads or writes a file
            "--safe-mode",  // no CLAUDE.md / MEMORY.md / skills / MCP leakage
            "--no-session-persistence",
            "--output-format", "json",  // the only safe failure signal
        ]
    }

    /// The XML-ish tag each pass's input is wrapped in on stdin.
    ///
    /// Load-bearing, not decoration. Without it the system prompt ended in a dangling
    /// `TRANSCRIÇÃO:` label while the text arrived as a separate user turn, and the
    /// model would read a *clean* dictation as a request addressed to it — answering
    /// the transcript ("quer que eu documente isso?") instead of transforming it.
    /// Measured at ~49% of runs on the typed acceptance case (22/45), and 0/15 once
    /// the input is delimited. Disfluent speech never triggered it: the cleaner the
    /// dictation, the more it reads as a prompt.
    ///
    /// It also bounds a second problem the app has by construction: dictated speech
    /// is arbitrary text, and a user who dictates something shaped like an instruction
    /// must still get it transformed, never obeyed.
    /// Each pass names the artifact it receives, so the delimiter reads as a label
    /// for the data rather than boilerplate.
    public enum InputTag {
        /// Pass 1 receives the raw transcript.
        public static let transcript = "transcricao"
        /// Pass 2 receives pass 1's marked output.
        public static let annotated = "texto_anotado"
    }

    /// Wrap a pass's input in its delimiter, marking the turn as data to transform
    /// rather than a request to answer.
    static func delimited(_ input: String, tag: String) -> String {
        "<\(tag)>\n\(input)\n</\(tag)>"
    }

    /// The subprocess environment: exactly the four variables every measurement in
    /// the contract was taken under. `HOME` is load-bearing — without it `claude`
    /// fails "Not logged in" (auth lives at `~/.claude/.credentials.json`). The rest
    /// of the parent environment is dropped so nothing leaks into the call.
    public static func environment(base: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "PATH", "TMPDIR"] where base[key] != nil {
            env[key] = base[key]
        }
        return env
    }

    /// Judge one pass's raw process result. Pure, so the failure gating — the whole
    /// point of the contract — is unit-testable without the binary. Success is
    /// `is_error == false`, a zero exit, and a non-empty `result`; anything else is
    /// a typed failure. `subtype` is never read (it lies `"success"` on every error).
    public static func outcome(
        rc: Int32, stdout: Data, stderr: String, stage: Stage
    ) -> Result<String, OrganizationError> {
        // Empty stdin, a crash, or `text` output all produce non-JSON on stdout.
        guard let object = try? JSONSerialization.jsonObject(with: stdout),
            let json = object as? [String: Any]
        else {
            return .failure(.failed(
                stage: stage, reason: .cliError,
                detail: stderr.isEmpty ? "claude produced no JSON on stdout" : stderr))
        }
        // Absent `is_error` is treated as an error: never assume success from a
        // shape we do not recognise.
        let isError = json["is_error"] as? Bool ?? true
        let result = json["result"] as? String ?? ""
        guard !isError, rc == 0 else {
            // On failure the CLI puts English error prose in `result`; prefer it,
            // fall back to stderr. (`api_error_status` is null for network/auth.)
            let detail = result.isEmpty ? stderr : result
            return .failure(.failed(stage: stage, reason: .cliError, detail: detail))
        }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(.failed(stage: stage, reason: .emptyOutput, detail: "claude returned an empty result"))
        }
        return .success(text)
    }

    public func annotate(_ transcript: String) async throws(OrganizationError) -> String {
        try await run(
            prompt: pass1Prompt, input: transcript, tag: InputTag.transcript, stage: .pass1)
    }

    public func rewrite(_ annotated: String) async throws(OrganizationError) -> String {
        try await run(
            prompt: pass2Prompt, input: annotated, tag: InputTag.annotated, stage: .pass2)
    }

    /// Run one pass: launch `claude`, feed `input` on stdin, await exit, and gate the
    /// result through `outcome`. Runs off the calling actor so a pass (network-bound,
    /// seconds long, and with no built-in timeout on a dead network) never blocks it,
    /// and is killed if the enclosing task is cancelled — the manual "stop" and the
    /// graceful quit are the answer to that hang, not an app-imposed timeout.
    private func run(
        prompt: String, input: String, tag: String, stage: Stage
    ) async throws(OrganizationError) -> String {
        let environment = Self.environment(base: ProcessInfo.processInfo.environment)
        let arguments = Self.arguments(systemPrompt: prompt)
        let result: SubprocessResult
        do {
            result = try await runner.run(
                executable: claude, arguments: arguments, environment: environment,
                stdin: Data(Self.delimited(input, tag: tag).utf8))
        } catch {
            throw OrganizationError.failed(stage: stage, reason: .missingBinary, detail: "\(error)")
        }

        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.outcome(
            rc: result.terminationStatus, stdout: result.stdout,
            stderr: String(stderr.suffix(2000)), stage: stage
        ) {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

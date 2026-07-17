import Foundation

/// One prerequisite the app checks at launch (SPEC "First-run preflight").
public enum PreflightCheck: String, Sendable, Equatable, CaseIterable {
    /// `mlx_whisper` is on disk at its absolute path.
    case mlxWhisper
    /// `ffmpeg` is on disk at its absolute path.
    case ffmpeg
    /// `claude` is on disk at its absolute path.
    case claude
    /// `claude` is logged in — read as the presence of its credentials file, never as
    /// a burned CLI call (SPEC).
    case claudeLogin
    /// The ~1.5 GB Whisper model is in the HuggingFace cache.
    case whisperModel
    /// Input Monitoring is granted, so the hotkey can hear (ADR-0004).
    case inputMonitoring

    /// The pt-BR headline shown in the panel when this check fails.
    public var title: String {
        switch self {
        case .mlxWhisper: return "mlx_whisper não encontrado"
        case .ffmpeg: return "ffmpeg não encontrado"
        case .claude: return "claude não encontrado"
        case .claudeLogin: return "claude não está logado"
        case .whisperModel: return "modelo do Whisper não baixado"
        case .inputMonitoring: return "Monitoramento de Entrada desativado"
        }
    }

    /// The pt-BR line under the headline: what breaks, and the way out.
    public var detail: String {
        switch self {
        case .mlxWhisper: return "Sem ele não há transcrição. Instale com `brew install mlx-whisper`."
        case .ffmpeg: return "Sem ele o áudio não é convertido nem decodificado. Instale com `brew install ffmpeg`."
        case .claude: return "Sem ele não há organização do texto. Instale o Claude Code CLI."
        case .claudeLogin: return "A organização falha até você rodar `claude login` no terminal."
        case .whisperModel: return "São ~1,5 GB, uma vez só. Depois a transcrição roda offline."
        case .inputMonitoring: return "O atalho fica surdo até você permitir."
        }
    }

    /// What the panel can offer to fix, or nil when the check is report-only.
    ///
    /// Only two of the six are ours to fix. Installing a binary or logging into
    /// `claude` is the user's terminal, not something the app runs behind their back.
    public var fix: PreflightFix? {
        switch self {
        case .whisperModel: return .downloadWhisperModel
        case .inputMonitoring: return .openInputMonitoringSettings
        case .mlxWhisper, .ffmpeg, .claude, .claudeLogin: return nil
        }
    }
}

/// An action the panel can offer for a failing check.
public enum PreflightFix: Sendable, Equatable {
    /// Deep-link to the Input Monitoring pane in System Settings.
    case openInputMonitoringSettings
    /// Run the model download (`mlx_whisper` without `HF_HUB_OFFLINE=1`).
    case downloadWhisperModel

    /// The pt-BR button label, kept beside the titles it sits under rather than in the
    /// view, so the panel's wording lives in one place (as `PanelModel`'s does).
    public var title: String {
        switch self {
        case .openInputMonitoringSettings: return "Abrir Ajustes do Sistema…"
        case .downloadWhisperModel: return "Baixar modelo"
        }
    }
}

/// One check and how it came out.
public struct PreflightResult: Sendable, Equatable, Identifiable {
    public let check: PreflightCheck
    public let isSatisfied: Bool

    public var id: String { check.rawValue }

    public init(check: PreflightCheck, isSatisfied: Bool) {
        self.check = check
        self.isSatisfied = isSatisfied
    }
}

/// The outcome of one preflight run: every check, in a fixed order, satisfied or not.
///
/// It is a report, never a gate. Nothing here blocks the hotkey — a prerequisite that
/// is missing at capture time lands the recording as a retryable `failed`/`missing_binary`
/// item (`TranscriptionLane`, `Organizer`), so a thought is never lost to a dependency.
public struct PreflightReport: Sendable, Equatable {
    public let results: [PreflightResult]

    public init(results: [PreflightResult]) {
        self.results = results
    }

    /// Everything green. The launch state on a working machine.
    public static let satisfied = PreflightReport(
        results: PreflightCheck.allCases.map { PreflightResult(check: $0, isSatisfied: true) })

    public var failures: [PreflightResult] { results.filter { !$0.isSatisfied } }

    public var isSatisfied: Bool { failures.isEmpty }

    /// Input Monitoring is denied: the hotkey is deaf. Its own menubar tier
    /// (`needsPermission`), because it is the one failure with a one-click fix and a
    /// specific glyph to say so.
    public var needsPermission: Bool {
        !(results.first { $0.check == .inputMonitoring }?.isSatisfied ?? true)
    }

    /// Any *other* prerequisite is missing. These aggregate into the `failed` icon
    /// tier (SPEC): the glyph says "something needs you", the panel says which.
    public var hasFailedPrerequisite: Bool {
        failures.contains { $0.check != .inputMonitoring }
    }
}

/// Where preflight looks. Split from the run so tests point it at a temp tree and the
/// app points it at the real machine.
public struct PreflightConfiguration: Sendable {
    /// The three binaries, by absolute path (ADR-0002).
    public let paths: ToolchainPaths
    /// `claude`'s credentials file — its presence is the login check.
    public let credentials: URL
    /// The HuggingFace cache holding the Whisper model.
    public let cache: WhisperModelCache

    public init(paths: ToolchainPaths, credentials: URL, cache: WhisperModelCache) {
        self.paths = paths
        self.credentials = credentials
        self.cache = cache
    }

    /// The machine as it really is. `claude` keeps its credentials under `$HOME`
    /// (`docs/research/claude-cli-shell-out-contract.md`); the app is unsandboxed
    /// (ADR-0002), so `NSHomeDirectory()` is the real home, not a container.
    public static let defaults = PreflightConfiguration(
        paths: .defaults,
        credentials: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json"),
        cache: .default)
}

/// The launch-time gate: check the prerequisites, report what is missing, fix nothing
/// on its own (SPEC "First-run preflight").
///
/// A read, not a poll. The app runs it at launch and re-runs it on focus and
/// panel-open, which is also how a mid-session grant or a finished model download
/// stops being reported.
public enum Preflight {
    /// Run every check. Cheap enough for the main actor: five `stat`s and a `Bool`.
    ///
    /// - Parameters:
    ///   - configuration: where to look.
    ///   - inputMonitoringGranted: `CGPreflightListenEventAccess()`, never the Settings
    ///     toggle — the toggle lies after a DR-invalidating rebuild (ADR-0005). Passed
    ///     in because it is a CoreGraphics call and this target is pure.
    public static func run(
        configuration: PreflightConfiguration = .defaults,
        inputMonitoringGranted: Bool
    ) -> PreflightReport {
        // Presence only, never executability: the SPEC's `stat` check. A binary that is
        // there but unusable dies as `missing_binary` at capture time, retryable.
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        return PreflightReport(results: [
            PreflightResult(check: .mlxWhisper, isSatisfied: exists(configuration.paths.mlxWhisper)),
            PreflightResult(check: .ffmpeg, isSatisfied: exists(configuration.paths.ffmpeg)),
            PreflightResult(check: .claude, isSatisfied: exists(configuration.paths.claude)),
            PreflightResult(check: .claudeLogin, isSatisfied: exists(configuration.credentials.path)),
            PreflightResult(
                check: .whisperModel, isSatisfied: configuration.cache.isCached(model: Transcriber.model)),
            PreflightResult(check: .inputMonitoring, isSatisfied: inputMonitoringGranted),
        ])
    }
}

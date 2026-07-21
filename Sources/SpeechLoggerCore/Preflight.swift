import Foundation

/// One prerequisite the app checks at launch.
public enum PreflightCheck: String, Sendable, Equatable, CaseIterable {
    /// `mlx_whisper` is on disk at its absolute path.
    case mlxWhisper
    /// `ffmpeg` is on disk at its absolute path.
    case ffmpeg
    /// `claude` is on disk at its absolute path.
    case claude
    /// `claude` is logged in — read as the presence of its credentials file, never as
    /// a burned CLI call.
    case claudeLogin
    /// The ~1.5 GB Whisper model is in the HuggingFace cache.
    case whisperModel
    /// Input Monitoring is granted, so the hotkey can hear (ADR-0004).
    case inputMonitoring
    /// The microphone grant is given, so the mic can open at all.
    case microphonePermission
    /// An input device exists to record from.
    case microphoneDevice
    /// The input device is unmuted and gained, so it would actually capture something.
    case microphoneLevel

    /// The rows that read one `MicrophoneState`. They are separate checks because each
    /// names a different thing to fix; they can never fail together, since the state
    /// picks exactly one of them (`MicrophoneState.failingCheck`).
    public static let microphoneChecks: [PreflightCheck] = [
        .microphonePermission, .microphoneDevice, .microphoneLevel,
    ]

    /// The pt-BR headline shown in the panel when this check fails.
    public var title: String {
        switch self {
        case .mlxWhisper: return "mlx_whisper não encontrado"
        case .ffmpeg: return "ffmpeg não encontrado"
        case .claude: return "claude não encontrado"
        case .claudeLogin: return "claude não está logado"
        case .whisperModel: return "modelo do Whisper não baixado"
        case .inputMonitoring: return "Monitoramento de Entrada desativado"
        case .microphonePermission: return "sem acesso ao microfone"
        case .microphoneDevice: return "nenhum microfone conectado"
        case .microphoneLevel: return "microfone mudo ou sem ganho"
        }
    }

    /// The pt-BR line under the headline: what breaks, and the way out.
    ///
    /// The three microphone lines name the *device* problem, never "nada foi ouvido" —
    /// the point of querying the device is to say what to fix instead of reporting an
    /// absence after the fact.
    public var detail: String {
        switch self {
        case .mlxWhisper: return "Sem ele não há transcrição. Instale com `brew install mlx-whisper`."
        case .ffmpeg: return "Sem ele o áudio não é convertido nem decodificado. Instale com `brew install ffmpeg`."
        case .claude: return "Sem ele não há organização do texto. Instale o Claude Code CLI."
        case .claudeLogin: return "A organização falha até você rodar `claude login` no terminal."
        case .whisperModel: return "São ~1,5 GB, uma vez só. Depois a transcrição roda offline."
        case .inputMonitoring: return "O atalho fica surdo até você permitir."
        case .microphonePermission:
            return "A gravação é recusada até você liberar o microfone para o app."
        case .microphoneDevice:
            return "Não há entrada de áudio para gravar. Conecte um microfone."
        case .microphoneLevel:
            return "O aparelho está aí, mas mudo ou com ganho zero: não captaria nada. "
                + "Ajuste o volume de entrada."
        }
    }

    /// What the panel can offer to fix, or nil when the check is report-only.
    ///
    /// Only what is ours to fix: the download we run, and the Settings pane that owns
    /// the problem. Installing a binary, logging into `claude` or plugging in a
    /// microphone is the user's terminal or the user's desk, not something a button does.
    public var fix: PreflightFix? {
        switch self {
        case .whisperModel: return .downloadWhisperModel
        case .inputMonitoring: return .openInputMonitoringSettings
        case .microphonePermission: return .openMicrophoneSettings
        case .microphoneLevel: return .openSoundSettings
        case .mlxWhisper, .ffmpeg, .claude, .claudeLogin, .microphoneDevice: return nil
        }
    }
}

extension MicrophoneState {
    /// The one check this device problem fails, or nil when the microphone is usable.
    ///
    /// The single place the device states and the panel's rows are married, so the two
    /// cannot drift: an exhaustive switch means a new state has to name the row that
    /// reports it, rather than silently reporting nothing while recordings are refused.
    public var failingCheck: PreflightCheck? {
        switch self {
        case .usable: return nil
        case .permissionDenied: return .microphonePermission
        case .noDevice: return .microphoneDevice
        case .silenced: return .microphoneLevel
        }
    }
}

/// An action the panel can offer for a failing check.
public enum PreflightFix: Sendable, Equatable {
    /// Deep-link to the Input Monitoring pane in System Settings.
    case openInputMonitoringSettings
    /// Deep-link to the Microphone privacy pane in System Settings.
    case openMicrophoneSettings
    /// Deep-link to the Sound pane, where the input device and its volume live.
    case openSoundSettings
    /// Run the model download (`mlx_whisper` without `HF_HUB_OFFLINE=1`).
    case downloadWhisperModel

    /// The pt-BR button label, kept beside the titles it sits under rather than in the
    /// view, so the panel's wording lives in one place (as `PanelModel`'s does).
    public var title: String {
        switch self {
        case .openInputMonitoringSettings: return "Abrir Ajustes do Sistema…"
        case .openMicrophoneSettings: return "Abrir Ajustes do Sistema…"
        case .openSoundSettings: return "Abrir Ajustes de Som…"
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
///
/// The microphone rows are the one place worth being precise about: an unusable device
/// does refuse a recording, but the refusal is `RecordingCoordinator`'s, taken from its
/// own query at the instant the key is pressed. This report is still only a report —
/// it is read at panel-open, and by then the device may have changed.
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
    /// tier: the glyph says "something needs you", the panel says which.
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
/// on its own.
///
/// A read, not a poll. The app runs it at launch and re-runs it on focus and
/// panel-open, which is also how a mid-session grant or a finished model download
/// stops being reported.
public enum Preflight {
    /// Run every check. Cheap enough for the main actor: five `stat`s and two queries
    /// answered by the caller.
    ///
    /// - Parameters:
    ///   - configuration: where to look.
    ///   - inputMonitoringGranted: `CGPreflightListenEventAccess()`, never the Settings
    ///     toggle — the toggle lies after a DR-invalidating rebuild (ADR-0005). Passed
    ///     in because it is a CoreGraphics call and this target is pure.
    ///   - microphone: the device as it reports itself (AVFoundation + CoreAudio),
    ///     injected for the same reason. A dead mic is read from the hardware, never
    ///     inferred from a recording that came back silent.
    public static func run(
        configuration: PreflightConfiguration = .defaults,
        inputMonitoringGranted: Bool,
        microphone: MicrophoneState
    ) -> PreflightReport {
        // Presence only, never executability: a plain `stat` check. A binary that is
        // there but unusable dies as `missing_binary` at capture time, retryable.
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let results = [
            PreflightResult(check: .mlxWhisper, isSatisfied: exists(configuration.paths.mlxWhisper)),
            PreflightResult(check: .ffmpeg, isSatisfied: exists(configuration.paths.ffmpeg)),
            PreflightResult(check: .claude, isSatisfied: exists(configuration.paths.claude)),
            PreflightResult(check: .claudeLogin, isSatisfied: exists(configuration.credentials.path)),
            PreflightResult(
                check: .whisperModel, isSatisfied: configuration.cache.isCached(model: Transcriber.model)),
            PreflightResult(check: .inputMonitoring, isSatisfied: inputMonitoringGranted),
        ]
        // One state, several rows: whichever device problem is there is the only one
        // reported, so the banner names what to fix instead of listing everything a
        // microphone could be wrong about. Derived from the state rather than compared
        // row by row, so a new `MicrophoneState` case cannot end up refusing recordings
        // while the panel shows nothing.
        let microphoneResults = PreflightCheck.microphoneChecks.map {
            PreflightResult(check: $0, isSatisfied: microphone.failingCheck != $0)
        }
        return PreflightReport(results: results + microphoneResults)
    }
}

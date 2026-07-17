import Foundation

/// Why a model download failed.
public enum WhisperModelDownloadError: Error, Equatable {
    /// `mlx_whisper` could not be launched (absent / not executable) — its own
    /// preflight check is failing too.
    case launchFailed(String)
    /// The run finished and the model is *still* not cached. `detail` carries the
    /// stderr tail, the only place the cause shows (no network, HF down, no disk).
    case incomplete(detail: String)
    /// A filesystem failure staging the run's throwaway input.
    case io(String)

    /// The pt-BR line the panel shows when the click did not work. Without it the
    /// spinner would simply stop and leave the same banner behind, which is the silent
    /// failure story 37 exists to prevent. The `detail` stays in the log: it is a
    /// stderr tail, not something to read in a menubar popover.
    public var message: String {
        switch self {
        case .launchFailed: return "Não deu pra executar o mlx_whisper. Confira a instalação."
        case .incomplete: return "O download não terminou. Confira a conexão e tente de novo."
        case .io: return "Não deu pra preparar o download."
        }
    }
}

/// The one thing preflight fixes: downloading the ~1.5 GB Whisper model, as a
/// deliberate user-clicked step (SPEC "First-run preflight").
///
/// It is a normal `mlx_whisper` run with two differences from a dictation:
///   1. **No `HF_HUB_OFFLINE=1`.** That variable is exactly what makes a dictation
///      never stall on the network, and exactly what would make this a no-op. This is
///      the single run allowed to reach HuggingFace.
///   2. **The audio is throwaway silence.** The CLI needs a file to work on; the
///      transcript it writes is discarded with the temp directory. The download is the
///      product of this run, not the text.
///
/// The argv is `Transcriber`'s, unchanged, so what lands in the cache is the model the
/// dictation pins — a download of anything else would leave preflight red forever.
/// Success is the cache, never the exit code (`mlx_whisper` exits 0 on every failure).
public struct WhisperModelDownloader: Sendable {
    private let mlxWhisper: String
    private let ffmpegDir: String
    private let cache: WhisperModelCache

    public init(paths: ToolchainPaths = .defaults, cache: WhisperModelCache = .default) {
        self.mlxWhisper = paths.mlxWhisper
        self.ffmpegDir = (paths.ffmpeg as NSString).deletingLastPathComponent
        self.cache = cache
    }

    /// The transcription environment with `HF_HUB_OFFLINE` **removed** — including
    /// when the app inherited it from the user's own shell, which would otherwise turn
    /// the download into a silent no-op.
    public static func environment(base: [String: String], ffmpegDir: String) -> [String: String] {
        var env = Transcriber.environment(base: base, ffmpegDir: ffmpegDir)
        env["HF_HUB_OFFLINE"] = nil
        return env
    }

    /// Download the model, or throw. Long (~1.5 GB) and cancellable: the subprocess is
    /// killed if the enclosing task is cancelled, and a partial download is resumable
    /// by simply running it again (HuggingFace caches by blob).
    public func download() async throws(WhisperModelDownloadError) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-model-\(UUID().uuidString)", isDirectory: true)
        let audio = workspace.appendingPathComponent("silence.wav")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try SilentWAV.data(seconds: 0.2).write(to: audio)
        } catch {
            throw WhisperModelDownloadError.io("staging the download run: \(error)")
        }
        // One cleanup covers every exit: the transcript of silence is not wanted.
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stderr = try await run(
            arguments: Transcriber.arguments(
                input: audio.path, outputDir: workspace.path, outputName: "silence-out"))

        // The exit code said nothing (always 0). The cache is the only honest answer.
        guard cache.isCached(model: Transcriber.model) else {
            throw WhisperModelDownloadError.incomplete(detail: stderr)
        }
    }

    /// Launch `mlx_whisper`, await its exit, and return its stderr tail (a HuggingFace
    /// progress bar on success, the cause on failure). Runs off the calling actor so
    /// the download never blocks the UI.
    private func run(arguments: [String]) async throws(WhisperModelDownloadError) -> String {
        do {
            return try await runCapturingStderrTail(
                executable: mlxWhisper, arguments: arguments,
                environment: Self.environment(
                    base: ProcessInfo.processInfo.environment, ffmpegDir: ffmpegDir))
        } catch {
            throw WhisperModelDownloadError.launchFailed("\(error)")
        }
    }
}

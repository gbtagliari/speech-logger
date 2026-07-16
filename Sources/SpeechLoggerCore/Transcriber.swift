import Foundation

/// Why a transcription failed.
public enum TranscriptionError: Error, Equatable {
    /// `mlx_whisper` ran but produced no output file, or an empty one. Per the
    /// shell-out contract it exits 0 on every failure (missing input, ffmpeg off
    /// PATH, bad model, corrupt audio), so a non-empty output file is the *only*
    /// success signal — its absence is this error. `detail` carries the process's
    /// stderr tail, which is where those four causes actually differ (each has a
    /// telltale line: `FileNotFoundError: 'ffmpeg'`, an HF 404, a `CalledProcessError`).
    case emptyOutput(detail: String)
    /// The `mlx_whisper` binary itself could not be launched (absent / not
    /// executable). Distinct from `emptyOutput`: the process never started.
    case launchFailed(String)
    /// A filesystem failure moving the finished transcript into place.
    case io(String)
}

/// The transcription seam (concrete impl: `Transcriber` over `mlx_whisper`).
public protocol Transcribing: Sendable {
    /// Transcribe `audio`, writing the raw transcript to `transcript`. Throws
    /// `TranscriptionError` on any failure; on success `transcript` exists and is
    /// non-empty. The destination is left untouched on failure.
    func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError)
}

/// Transcribes an item's audio to raw text by shelling out to `mlx_whisper`
/// (ADR-0002), the single serial lane's per-item worker (ADR-0006). The command is
/// pinned to `whisper-large-v3-turbo`, Portuguese, and the anti-repetition guard;
/// every flag is load-bearing (`docs/research/mlx-whisper-shell-out-contract.md`).
///
/// Two facts from that contract shape this:
///   1. **`mlx_whisper` exits 0 on every failure.** `terminationStatus` is
///      ignored; success is the output file existing and being non-empty.
///   2. **A wrong model does not fail, it lies** (dropping `--model` silently
///      defaults to `whisper-tiny`, which mis-hears our own samples). The model is
///      pinned in the argv and asserted by tests; the end-to-end test against the
///      real samples is the runtime proof the right model ran.
///
/// Like `AudioEncoder`, the run writes a sibling temp file inside the destination
/// directory and renames it into place, so a reader never sees a half-written
/// transcript and a failed run leaves nothing to flip the item's state on.
public struct Transcriber: Transcribing {
    private let mlxWhisper: String
    private let ffmpegDir: String

    /// The pinned model. Dropping `--model` defaults to `whisper-tiny` *silently*;
    /// this is the whole reason the model is asserted (issue #17).
    public static let model = "mlx-community/whisper-large-v3-turbo"

    /// - Parameters:
    ///   - mlxWhisper: absolute path to `mlx_whisper` (not on a GUI app's `PATH`).
    ///   - ffmpeg: absolute path to `ffmpeg`. `mlx_whisper` decodes audio by shelling
    ///     out to `ffmpeg` *by name*, so its directory must be on the subprocess
    ///     `PATH` or every decode dies `FileNotFoundError: 'ffmpeg'` (empty output).
    public init(
        mlxWhisper: String = ToolchainPaths.defaults.mlxWhisper,
        ffmpeg: String = ToolchainPaths.defaults.ffmpeg
    ) {
        self.mlxWhisper = mlxWhisper
        self.ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent
    }

    /// The pinned `mlx_whisper` argv. Built as an array (never a shell string).
    /// `--output-name` is dot-free (`mlx_whisper` truncates it at the first dot),
    /// so the path we predict is the path that exists.
    public static func arguments(input: String, outputDir: String, outputName: String) -> [String] {
        [
            input,
            "--model", model,
            "--language", "pt",
            "--condition-on-previous-text", "False",
            "--temperature", "0",
            "--verbose", "False",
            "--output-format", "txt",
            "--output-name", outputName,
            "--output-dir", outputDir,
        ]
    }

    /// The subprocess environment: `HF_HUB_OFFLINE=1` so a dictation never stalls on
    /// the network (the model is preflight-downloaded), and `ffmpegDir` prepended to
    /// `PATH` so `mlx_whisper` can find `ffmpeg` under a GUI-launched app's bare env.
    public static func environment(base: [String: String], ffmpegDir: String) -> [String: String] {
        var env = base
        env["HF_HUB_OFFLINE"] = "1"
        env["PATH"] = env["PATH"].map { "\(ffmpegDir):\($0)" } ?? ffmpegDir
        return env
    }

    public func transcribe(audio: URL, to transcript: URL) async throws(TranscriptionError) {
        let outputDir = transcript.deletingLastPathComponent()
        // A dot-free temp stem in the same directory: `mlx_whisper` writes
        // `<stem>.txt` and truncates the name at any dot, so a plain suffix keeps
        // the predicted path exact. Renamed into place on success (atomic, same dir).
        let stem = transcript.deletingPathExtension().lastPathComponent
        let outputName = stem + "-partial"
        let produced = outputDir.appendingPathComponent(outputName + ".txt")
        // One cleanup covers every exit: on success the temp is already renamed away.
        defer { try? FileManager.default.removeItem(at: produced) }

        let stderr = try await run(
            arguments: Self.arguments(
                input: audio.path, outputDir: outputDir.path, outputName: outputName))

        // The contract's only success signal: the file exists and is non-empty.
        // `mlx_whisper`'s exit code told us nothing (always 0). On failure its stderr
        // is the only clue to which cause fired, so it rides along in the error.
        guard let size = try? FileManager.default.attributesOfItem(atPath: produced.path)[.size] as? Int,
            size > 0
        else {
            throw TranscriptionError.emptyOutput(detail: stderr)
        }

        do {
            // A retry may have left a prior transcript.txt; clear it, then rename the
            // fresh output into place (atomic within the same directory).
            if FileManager.default.fileExists(atPath: transcript.path) {
                try FileManager.default.removeItem(at: transcript)
            }
            try FileManager.default.moveItem(at: produced, to: transcript)
        } catch {
            throw TranscriptionError.io("moving transcript into place: \(error)")
        }
    }

    /// Launch `mlx_whisper`, await its exit, and return its captured stderr tail.
    /// `terminationStatus` is deliberately discarded (the contract: it is 0 on every
    /// failure); the caller judges success by the output file. stderr is *not* a
    /// failure signal either (it holds a HuggingFace progress bar even on success),
    /// so it is captured only to enrich a later `emptyOutput` diagnosis, never tested.
    /// Runs off the calling actor so a long transcription never blocks it. Throws
    /// `launchFailed` only if the process cannot start.
    private func run(arguments: [String]) async throws(TranscriptionError) -> String {
        let mlxWhisper = mlxWhisper
        let environment = Self.environment(
            base: ProcessInfo.processInfo.environment, ffmpegDir: ffmpegDir)
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: mlxWhisper)
                process.arguments = arguments
                process.environment = environment
                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe
                process.terminationHandler = { _ in
                    let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    // Cap the tail so a runaway log never bloats meta.json.
                    let stderr = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: String(stderr.suffix(2000)))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: TranscriptionError.launchFailed("\(error)"))
                }
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            // Unreachable: the continuation only ever throws `launchFailed`. Present
            // so the untyped continuation collapses back to the typed throw.
            throw TranscriptionError.launchFailed("\(error)")
        }
    }
}

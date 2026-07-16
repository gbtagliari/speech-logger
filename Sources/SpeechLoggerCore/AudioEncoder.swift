import Foundation

/// Why an encode failed.
public enum EncodeError: Error, Equatable {
    /// `ffmpeg` exited non-zero. `stderr` is the tail of its diagnostics.
    case ffmpegFailed(status: Int32, stderr: String)
    /// `ffmpeg` exited 0 but wrote no output (or an empty file).
    case emptyOutput
    /// A filesystem or process-launch failure.
    case io(String)
}

/// Encodes a recorded wav to the retained mp3 by shelling out to `ffmpeg`
/// (ADR-0002): **mono / 16 kHz / 64 kbps**. The mp3 is the recording, the
/// transcriber input, and the retained artifact at once, so the kept file
/// reproduces production exactly (SPEC "The pipeline"). 16 kHz is Whisper's exact
/// acceptance-set sample format.
///
/// The encode writes a sibling temp file inside the destination directory, then
/// renames it into place — so a reader never sees a half-written mp3 and an
/// interrupted encode leaves nothing to flip the item's state on.
public struct AudioEncoder: AudioEncoding {
    private let ffmpeg: String

    public init(ffmpeg: String = ToolchainPaths.defaults.ffmpeg) {
        self.ffmpeg = ffmpeg
    }

    /// The pinned `ffmpeg` argv. Built as an array (never a shell string). `-f mp3`
    /// is explicit because the temp output name does not end in `.mp3`, so the
    /// format cannot be inferred from the extension.
    public static func arguments(input: String, output: String) -> [String] {
        [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", input,
            "-ac", "1",  // mono
            "-ar", "16000",  // 16 kHz
            "-c:a", "libmp3lame",
            "-b:a", "64k",  // 64 kbps
            "-f", "mp3",
            output,
        ]
    }

    /// Encode `wav` into `mp3`. Success requires both a zero exit code *and* a
    /// non-empty output file. On failure the destination is left untouched.
    public func encode(wav: URL, to mp3: URL) async throws(EncodeError) {
        let temp = mp3.deletingLastPathComponent()
            .appendingPathComponent(mp3.lastPathComponent + ".tmp")
        // One cleanup covers every exit: on success the temp is already gone
        // (renamed into place), so this is a harmless no-op there.
        defer { try? FileManager.default.removeItem(at: temp) }

        let result: (status: Int32, stderr: String)
        do {
            result = try await run(arguments: Self.arguments(input: wav.path, output: temp.path))
        } catch {
            throw EncodeError.io("\(error)")
        }

        guard result.status == 0 else {
            throw EncodeError.ffmpegFailed(status: result.status, stderr: result.stderr)
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int,
            size > 0
        else {
            throw EncodeError.emptyOutput
        }

        do {
            // A fresh item has no prior audio.mp3; a retry might. Clear it, then
            // rename the temp into place (atomic within the same directory).
            if FileManager.default.fileExists(atPath: mp3.path) {
                try FileManager.default.removeItem(at: mp3)
            }
            try FileManager.default.moveItem(at: temp, to: mp3)
        } catch {
            throw EncodeError.io("renaming encoded mp3 into place: \(error)")
        }
    }

    /// Launch `ffmpeg` and await its exit, capturing stderr. Runs off the calling
    /// actor so a long encode never blocks the caller.
    private func run(arguments: [String]) async throws -> (status: Int32, stderr: String) {
        let ffmpeg = ffmpeg
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (finished.terminationStatus, stderr))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

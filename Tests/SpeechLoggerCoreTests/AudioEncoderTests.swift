import Foundation
import Testing

@testable import SpeechLoggerCore

/// The `ffmpeg` encode contract (ADR-0002): the argv is pinned to
/// **mono / 16 kHz / 64 kbps mp3**, and success is a non-empty output file, not a
/// hopeful exit code. The pure-argv tests catch a dropped flag; the guarded
/// integration test proves the real command produces the required format.
struct AudioEncoderTests {
    // MARK: - Pinned argv

    @Test("the argv encodes to mono, 16 kHz, 64 kbps mp3")
    func argvPinsFormat() {
        let argv = AudioEncoder.arguments(input: "/in.wav", output: "/out.tmp")
        // Each parameter is present as an adjacent flag/value pair.
        #expect(adjacent(argv, "-ac", "1"))  // mono
        #expect(adjacent(argv, "-ar", "16000"))  // 16 kHz
        #expect(adjacent(argv, "-b:a", "64k"))  // 64 kbps
        #expect(adjacent(argv, "-f", "mp3"))  // explicit format (temp name isn't .mp3)
        #expect(adjacent(argv, "-i", "/in.wav"))
        // The output path is the final argument.
        #expect(argv.last == "/out.tmp")
    }

    @Test("the argv never overwrites interactively and stays quiet")
    func argvIsNonInteractive() {
        let argv = AudioEncoder.arguments(input: "/in.wav", output: "/out.tmp")
        #expect(argv.contains("-nostdin"))
        #expect(argv.contains("-y"))
    }

    // MARK: - End-to-end encode (requires ffmpeg)

    @Test(
        "a recorded wav encodes to a non-empty mono 16 kHz mp3",
        .enabled(if: FileManager.default.fileExists(atPath: ToolchainPaths.defaults.ffmpeg)))
    func encodesRealWav() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 2 s tone at 48 kHz stereo, mimicking an AVAudioEngine capture.
        let wav = dir.appendingPathComponent("source.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-ac", "2", "-ar", "48000", wav.path,
        ])

        let mp3 = dir.appendingPathComponent("audio.mp3")
        try await AudioEncoder().encode(wav: wav, to: mp3)

        // The mp3 exists, is non-empty, and no temp file is left behind.
        #expect(FileManager.default.fileExists(atPath: mp3.path))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: mp3.path)[.size] as? Int)
        #expect(size > 0)
        #expect(!FileManager.default.fileExists(atPath: mp3.path + ".tmp"))

        // ffmpeg reads it back as mono, 16 kHz — the format the contract requires.
        let info = try probe(mp3)
        #expect(info.contains("16000 Hz"))
        #expect(info.contains("mono"))
    }

    // MARK: - Helpers

    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return false }
        return argv[index + 1] == value
    }

    private func runFFmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolchainPaths.defaults.ffmpeg)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// `ffmpeg -i <file>` prints stream info to stderr; return it for assertions.
    private func probe(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolchainPaths.defaults.ffmpeg)
        process.arguments = ["-hide_banner", "-i", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

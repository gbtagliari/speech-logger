import Foundation
import Testing

@testable import SpeechLoggerCore

/// The `mlx_whisper` shell-out contract (ADR-0002, issue #17): the argv is pinned to
/// `whisper-large-v3-turbo`, Portuguese, and the anti-repetition guard, and success
/// is a non-empty output file, not the (always-zero) exit code. The pure-argv tests
/// catch a dropped flag — the model one especially, because a wrong model does not
/// fail, it lies — and the guarded end-to-end test proves the real command produces
/// the right transcript against the real samples.
struct TranscriberTests {
    // MARK: - Pinned argv

    @Test("the argv pins the model — a dropped --model silently means whisper-tiny")
    func argvPinsModel() {
        let argv = Transcriber.arguments(input: "/a.mp3", outputDir: "/dir", outputName: "transcript-partial")
        #expect(adjacent(argv, "--model", "mlx-community/whisper-large-v3-turbo"))
        #expect(Transcriber.model == "mlx-community/whisper-large-v3-turbo")
    }

    @Test("the argv pins Portuguese and the anti-repetition / determinism flags")
    func argvPinsLanguageAndGuards() {
        let argv = Transcriber.arguments(input: "/a.mp3", outputDir: "/dir", outputName: "transcript-partial")
        #expect(adjacent(argv, "--language", "pt"))
        #expect(adjacent(argv, "--condition-on-previous-text", "False"))  // guards the repetition loop
        #expect(adjacent(argv, "--temperature", "0"))
        #expect(adjacent(argv, "--verbose", "False"))
    }

    @Test("the argv pins txt output at the predicted, dot-free path")
    func argvPinsOutput() {
        let argv = Transcriber.arguments(input: "/a.mp3", outputDir: "/dir", outputName: "transcript-partial")
        #expect(adjacent(argv, "--output-format", "txt"))
        #expect(adjacent(argv, "--output-name", "transcript-partial"))  // dot-free: mlx truncates at first dot
        #expect(adjacent(argv, "--output-dir", "/dir"))
        #expect(argv.first == "/a.mp3")  // the audio is the positional argument
    }

    // MARK: - Environment

    @Test("the environment forces HF_HUB_OFFLINE and puts ffmpeg on PATH")
    func environmentIsOfflineAndFindsFfmpeg() {
        let env = Transcriber.environment(
            base: ["PATH": "/usr/bin"], ffmpegDir: "/opt/homebrew/bin")
        // Offline so a transcription never stalls on the network.
        #expect(env["HF_HUB_OFFLINE"] == "1")
        // mlx_whisper shells out to `ffmpeg` by name; its dir must be on PATH.
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
    }

    @Test("the environment still sets PATH when the base has none")
    func environmentSetsPathFromEmpty() {
        let env = Transcriber.environment(base: [:], ffmpegDir: "/opt/homebrew/bin")
        #expect(env["PATH"] == "/opt/homebrew/bin")
    }

    // MARK: - Failure without the binary

    @Test("a missing mlx_whisper binary surfaces as launchFailed, not a false success")
    func missingBinaryLaunchFails() async {
        let transcriber = Transcriber(mlxWhisper: "/nonexistent/mlx_whisper", ffmpeg: "/opt/homebrew/bin/ffmpeg")
        let dir = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))

        await #expect(throws: TranscriptionError.self) {
            try await transcriber.transcribe(audio: audio, to: dir.appendingPathComponent("transcript.txt"))
        }
    }

    // MARK: - End-to-end (requires mlx_whisper + ffmpeg + the cached model + a sample)

    @Test(
        "a real sample transcribes to the expected pt-BR text — the right model ran",
        .enabled(if: SampleFixtures.transcriptionAvailable))
    func transcribesRealSample() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("transcript.txt")

        try await Transcriber().transcribe(audio: SampleFixtures.caso02, to: transcript)

        // The transcript exists, is non-empty, and no temp file is left behind.
        #expect(FileManager.default.fileExists(atPath: transcript.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript-partial.txt").path))
        let text = try String(contentsOf: transcript, encoding: .utf8)
        #expect(!text.isEmpty)
        // Distinctive words `whisper-tiny` mis-hears on this very sample (it renders
        // "Packers" as "vali", "daily" as "dele"). Their presence is the runtime
        // proof that the pinned turbo model ran, not the silent tiny default.
        #expect(text.contains("Packers"))
        #expect(text.localizedCaseInsensitiveContains("daily"))
    }

    @Test(
        "a corrupt input yields emptyOutput (mlx exits 0 and writes nothing)",
        .enabled(if: FileManager.default.fileExists(atPath: ToolchainPaths.defaults.mlxWhisper)))
    func corruptInputIsEmptyOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not decodable audio: mlx's ffmpeg decode fails, it exits 0, writes nothing.
        let audio = dir.appendingPathComponent("audio.mp3")
        try Data("not an mp3".utf8).write(to: audio)

        do {
            try await Transcriber().transcribe(
                audio: audio, to: dir.appendingPathComponent("transcript.txt"))
            Issue.record("expected emptyOutput, but transcribe succeeded")
        } catch let error as TranscriptionError {
            guard case .emptyOutput(let detail) = error else {
                Issue.record("expected emptyOutput, got \(error)")
                return
            }
            // The failure carries the stderr tail — the whole point of capturing it.
            #expect(!detail.isEmpty)
        }
    }

    // MARK: - Helpers

    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return false }
        return argv[index + 1] == value
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

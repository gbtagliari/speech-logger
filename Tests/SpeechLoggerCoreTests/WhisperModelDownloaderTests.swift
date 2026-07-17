import Foundation
import Testing

@testable import SpeechLoggerCore

/// The one thing preflight fixes: the model download, a user-clicked `mlx_whisper`
/// run *without* `HF_HUB_OFFLINE=1` (SPEC "First-run preflight").
struct WhisperModelDownloaderTests {
    private func emptyHub() -> WhisperModelCache {
        WhisperModelCache(
            hub: FileManager.default.temporaryDirectory
                .appendingPathComponent("hub-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: - The environment

    /// The whole point of the download run: transcription pins `HF_HUB_OFFLINE=1` so a
    /// dictation never stalls on the network, and with it set the download cannot
    /// happen. Inheriting it from the app's own env would make the fix a no-op.
    @Test("the download run drops HF_HUB_OFFLINE, even when inherited")
    func offlineIsDropped() {
        let env = WhisperModelDownloader.environment(
            base: ["HF_HUB_OFFLINE": "1"], ffmpegDir: "/opt/homebrew/bin")
        #expect(env["HF_HUB_OFFLINE"] == nil)
    }

    @Test("transcription still pins HF_HUB_OFFLINE — only the download run is online")
    func transcriptionStaysOffline() {
        let env = Transcriber.environment(base: [:], ffmpegDir: "/opt/homebrew/bin")
        #expect(env["HF_HUB_OFFLINE"] == "1")
    }

    @Test("ffmpeg's directory is on the PATH, as for a transcription")
    func ffmpegOnPath() {
        let env = WhisperModelDownloader.environment(
            base: ["PATH": "/usr/bin"], ffmpegDir: "/opt/homebrew/bin")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
    }

    // MARK: - Running it

    @Test("an absent mlx_whisper surfaces as launchFailed")
    func missingBinaryLaunchFails() async {
        let downloader = WhisperModelDownloader(
            paths: ToolchainPaths(
                mlxWhisper: "/nonexistent/mlx_whisper", ffmpeg: "/usr/bin/true", claude: "/usr/bin/true"),
            cache: emptyHub())
        await #expect(throws: WhisperModelDownloadError.self) { try await downloader.download() }
    }

    /// `mlx_whisper` exits 0 on every failure, so the exit code cannot say whether the
    /// download worked. The cache is the only answer: still empty means still owed.
    @Test("a run that leaves the cache empty fails, whatever it exited with")
    func silentFailureIsCaught() async throws {
        let downloader = WhisperModelDownloader(
            paths: ToolchainPaths(
                mlxWhisper: "/usr/bin/true", ffmpeg: "/usr/bin/true", claude: "/usr/bin/true"),
            cache: emptyHub())
        await #expect(throws: WhisperModelDownloadError.self) { try await downloader.download() }
    }

    @Test("a run that fills the cache succeeds")
    func cachedAfterRunSucceeds() async throws {
        let hub = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hub) }
        let snapshot = hub.appendingPathComponent(
            "models--mlx-community--whisper-large-v3-turbo/snapshots/rev", isDirectory: true)
        let refs = hub.appendingPathComponent(
            "models--mlx-community--whisper-large-v3-turbo/refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        try Data("rev".utf8).write(to: refs.appendingPathComponent("main"))

        let downloader = WhisperModelDownloader(
            paths: ToolchainPaths(
                mlxWhisper: "/usr/bin/true", ffmpeg: "/usr/bin/true", claude: "/usr/bin/true"),
            cache: WhisperModelCache(hub: hub))
        try await downloader.download()
    }
}

/// The throwaway audio the download run feeds `mlx_whisper` (its CLI needs a file).
struct SilentWAVTests {
    @Test("the header is a canonical 16 kHz mono 16-bit PCM wav")
    func canonicalHeader() {
        let wav = SilentWAV.data(seconds: 1)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8..<12] == Data("WAVE".utf8))
        #expect(wav[12..<16] == Data("fmt ".utf8))
        #expect(wav[36..<40] == Data("data".utf8))
        #expect(read32(wav, at: 24) == 16_000)  // sample rate
        #expect(read16(wav, at: 22) == 1)  // mono
        #expect(read16(wav, at: 34) == 16)  // bits per sample
    }

    @Test("the declared sizes match the bytes that are actually there")
    func sizesAreHonest() {
        let wav = SilentWAV.data(seconds: 0.5)
        let dataSize = read32(wav, at: 40)
        #expect(Int(dataSize) == 8_000 * 2)  // 0.5 s of 16-bit frames
        #expect(wav.count == 44 + Int(dataSize))
        #expect(read32(wav, at: 4) == UInt32(wav.count - 8))
    }

    @Test("it is silence")
    func isSilent() {
        #expect(SilentWAV.data(seconds: 0.2).dropFirst(44).allSatisfy { $0 == 0 })
    }

    /// A zero-frame wav is a file ffmpeg refuses; the floor keeps the download run
    /// from dying on its own input.
    @Test("a rounding-to-zero duration still produces a frame")
    func neverEmpty() {
        #expect(SilentWAV.data(seconds: 0).count > 44)
    }

    private func read16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func read32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }
}

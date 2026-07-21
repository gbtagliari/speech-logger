import Foundation
import SpeechLoggerCore

/// Shared access to the real acceptance-set samples the guarded end-to-end tests run
/// against (issue #17). One place so the path and availability check don't drift
/// between `TranscriberTests` and `TranscriptionLaneTests`.
enum SampleFixtures {
    /// `caso-02.mp3`: ~17 s of pt-BR speech whose ground truth contains the
    /// distinctive words `whisper-tiny` mis-hears ("Packers", "daily"), so a correct
    /// transcript is proof the pinned turbo model ran.
    static let caso02 = URL(fileURLWithPath: repoRoot)
        .appendingPathComponent(".scratch/dictation-tool/samples/caso-02.mp3")

    /// A real transcription needs both binaries and the sample present. The model is
    /// assumed cached (preflight's job); if it is not, an enabled test would surface it.
    static let transcriptionAvailable =
        FileManager.default.fileExists(atPath: ToolchainPaths.defaults.mlxWhisper)
        && FileManager.default.fileExists(atPath: ToolchainPaths.defaults.ffmpeg)
        && FileManager.default.fileExists(atPath: caso02.path)

    /// Anchored to this source file, not the process cwd (which `xcodebuild` sets to
    /// DerivedData): `.../Tests/SpeechLoggerCoreTests/ThisFile.swift` → three parents
    /// up is the repo root that holds `.scratch/`.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .path
}

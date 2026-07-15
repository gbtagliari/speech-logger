import Foundation
import Testing

@testable import SpeechLoggerCore

/// The config surface for the three shell-out binaries (ADR-0002). These tests
/// pin the contract: the paths are absolute (nothing relies on a GUI app's
/// `PATH`) and the defaults point at where the binaries actually live on the
/// build machine.
struct ToolchainPathsTests {
    @Test("mlx_whisper and ffmpeg default to the pinned Homebrew paths")
    func pinnedHomebrewPaths() {
        let paths = ToolchainPaths.defaults
        #expect(paths.mlxWhisper == "/opt/homebrew/bin/mlx_whisper")
        #expect(paths.ffmpeg == "/opt/homebrew/bin/ffmpeg")
    }

    @Test("claude defaults under the user home, so it is not hard-coded to one user")
    func claudeResolvesUnderHome() {
        #expect(ToolchainPaths.defaults.claude == NSHomeDirectory() + "/.local/bin/claude")
    }

    @Test("every default path is absolute (none relies on PATH)")
    func everyDefaultIsAbsolute() {
        for path in ToolchainPaths.defaults.all {
            #expect(path.hasPrefix("/"), "expected an absolute path, got: \(path)")
        }
    }

    @Test("all lists the three binaries in a fixed order")
    func allIsOrdered() {
        let paths = ToolchainPaths(mlxWhisper: "/a", ffmpeg: "/b", claude: "/c")
        #expect(paths.all == ["/a", "/b", "/c"])
    }

    @Test("it is an overridable value type, not fixed globals")
    func overridableValueType() {
        let custom = ToolchainPaths(
            mlxWhisper: "/x/mlx_whisper", ffmpeg: "/x/ffmpeg", claude: "/x/claude")
        #expect(custom != ToolchainPaths.defaults)
        #expect(custom.claude == "/x/claude")
    }
}

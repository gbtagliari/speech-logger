import Foundation

/// Absolute filesystem paths to the three external binaries the app shells out
/// to (ADR-0002): `mlx_whisper` (transcription), `ffmpeg` (audio encode), and
/// `claude` (both LLM passes).
///
/// The paths are absolute because none of these binaries is on a GUI-launched
/// app's `PATH`. This is the single config surface for them, and they are meant to
/// become user-configurable one day, so this is a value type with an overridable
/// initializer rather than bare global constants.
public struct ToolchainPaths: Equatable, Sendable {
    /// `mlx_whisper` — local transcription.
    public let mlxWhisper: String
    /// `ffmpeg` — audio encode (also invoked internally by `mlx_whisper` to decode).
    public let ffmpeg: String
    /// `claude` — the Claude Code CLI, run once per LLM pass.
    public let claude: String

    public init(mlxWhisper: String, ffmpeg: String, claude: String) {
        self.mlxWhisper = mlxWhisper
        self.ffmpeg = ffmpeg
        self.claude = claude
    }

    /// The paths as resolved on the build machine. `mlx_whisper` and `ffmpeg`
    /// are Homebrew binaries; `claude` lives under the user's home. These are the
    /// MVP defaults; making them user-editable is deferred.
    public static let defaults = ToolchainPaths(
        mlxWhisper: "/opt/homebrew/bin/mlx_whisper",
        ffmpeg: "/opt/homebrew/bin/ffmpeg",
        claude: NSHomeDirectory() + "/.local/bin/claude"
    )

    /// The three paths in a fixed order, for iteration (e.g. preflight presence checks).
    public var all: [String] { [mlxWhisper, ffmpeg, claude] }
}

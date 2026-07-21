import Foundation

/// The canonical state of a log item (CONTEXT.md, ADR-0003, ADR-0006).
///
/// The happy path forks by `ItemMode` after `transcribing`:
/// - braindump: `recording` -> `queued` -> `transcribing` -> `organizing` -> `organized`
/// - dictation: `recording` -> `queued` -> `transcribing` -> `transcribed`
///
/// `failed` and `cancelled` are terminal off-ramps shared by both. Which states a mode
/// can actually reach is `ItemMode.reaches(_:)`, not encoded here.
public enum ItemState: String, Codable, Sendable, CaseIterable {
    /// Mic is live, no content yet (a running clock).
    case recording
    /// Recording finished, waiting for the serial transcription lane (ADR-0006).
    case queued
    /// `mlx_whisper` is running.
    case transcribing
    /// Terminal, happy path, `mode: dictation` only: the transcript is the output and
    /// there is no organization stage to enter. `organized` cannot serve here — it
    /// names a stage that never runs for the mode.
    case transcribed
    /// The two LLM passes are running. `mode: braindump` only.
    case organizing
    /// Terminal, happy path, `mode: braindump` only: the final pass-2 text exists and
    /// is copyable.
    case organized
    /// Terminal, broke: carries `error: { stage, reason, detail, at }`.
    case failed
    /// Terminal, you stopped it: carries `stoppedAt: { stage, at }`.
    case cancelled

    /// A terminal state does not advance and is never touched by boot recovery.
    public var isTerminal: Bool {
        switch self {
        case .transcribed, .organized, .failed, .cancelled: return true
        case .recording, .queued, .transcribing, .organizing: return false
        }
    }
}

/// The pipeline stage a `failed`/`cancelled` item died at (CONTEXT.md).
public enum Stage: String, Codable, Sendable, CaseIterable {
    case recording
    case transcription
    case pass1
    case pass2
}

/// Why a `failed` item broke (CONTEXT.md). `timeout` is reserved; nothing in the
/// MVP produces it.
public enum FailureReason: String, Codable, Sendable, CaseIterable {
    case noSpeech = "no_speech"
    case emptyOutput = "empty_output"
    case cliError = "cli_error"
    case missingBinary = "missing_binary"
    case interrupted
    case timeout
}

import Foundation

/// The canonical state of a log item (CONTEXT.md, ADR-0003, ADR-0006). Supersedes
/// the four-state table in `PRD.md` §5.
///
/// Happy path: `recording` -> `queued` -> `transcribing` -> `organizing` ->
/// `organized`. `failed` and `cancelled` are terminal off-ramps.
public enum ItemState: String, Codable, Sendable, CaseIterable {
    /// Mic is live, no content yet (a running clock).
    case recording
    /// Recording finished, waiting for the serial transcription lane (ADR-0006).
    case queued
    /// `mlx_whisper` is running.
    case transcribing
    /// The two LLM passes are running.
    case organizing
    /// Terminal, happy path: the final pass-2 text exists and is copyable.
    case organized
    /// Terminal, broke: carries `error: { stage, reason, detail, at }`.
    case failed
    /// Terminal, you stopped it: carries `stoppedAt: { stage, at }`.
    case cancelled

    /// A terminal state does not advance and is never touched by boot recovery.
    public var isTerminal: Bool {
        switch self {
        case .organized, .failed, .cancelled: return true
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

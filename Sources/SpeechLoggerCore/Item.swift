import Foundation

/// The well-known file names inside an item directory (ADR-0003). The store's
/// content API takes any name; these are the canonical stages callers share.
public enum ItemFile {
    /// The state + timeline. Written last on every transition.
    public static let meta = "meta.json"
    /// The recording, the transcriber input, and the retained artifact at once.
    public static let audio = "audio.mp3"
    /// Raw `mlx_whisper` output.
    public static let transcript = "transcript.txt"
    /// The annotated pass-1 pivot (retained so the two-pass contract is auditable).
    public static let pass1 = "pass1.txt"
    /// The final pass-2 text. Exists only in `organized`; the only copyable-as-final text.
    public static let final = "final.txt"

    /// Everything derived from `audio.mp3`, in pipeline order. Reprocessing an item
    /// (#24) discards exactly these and keeps the audio, which is its input.
    public static let derived = [transcript, pass1, final]
}

/// A log item as seen by callers: its directory name (a ULID) and current meta.
/// The unit of work — one recording and everything derived from it (CONTEXT.md).
public struct Item: Equatable, Sendable, Identifiable {
    /// The directory name: a timestamp-sortable ULID (ADR-0003).
    public let id: String
    public let meta: ItemMeta

    public init(id: String, meta: ItemMeta) {
        self.id = id
        self.meta = meta
    }

    public var state: ItemState { meta.state }

    /// A stopped/broken item can be retried unless it died at `recording`, which
    /// has nothing to resume (ADR-0006).
    public var isRetryable: Bool {
        guard let stage = meta.deathStage else { return false }
        return stage != .recording
    }

    /// A settled item can be reprocessed — re-run whole from `audio.mp3` — when that
    /// audio is on disk, which is true of every item that got past the recording
    /// stage (#24).
    ///
    /// The `organized` arm is the whole difference from `isRetryable`: an item can reach
    /// the happy-path terminal and still hold the wrong text (the app deliberately does
    /// not judge fidelity at runtime), and retry has no death stage to resume from there.
    /// Off the happy path the two agree, but for different reasons — retry asks "is there
    /// a stage to resume?", reprocess asks "is there audio to run again?".
    public var isReprocessable: Bool {
        meta.state == .organized || isRetryable
    }
}

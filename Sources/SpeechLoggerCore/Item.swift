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
    /// has nothing to resume (SPEC "Storage and the item state machine", ADR-0006).
    public var isRetryable: Bool {
        switch meta.state {
        case .failed: return meta.error?.stage != .recording
        case .cancelled: return meta.stoppedAt?.stage != .recording
        case .recording, .queued, .transcribing, .organizing, .organized: return false
        }
    }
}

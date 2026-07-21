import Foundation

/// The single error type the item store throws (Swift 6 typed throws). Foundation
/// errors from the filesystem are wrapped into `.io` so callers see one type.
public enum StoreError: Error, Equatable {
    /// No item directory with this id, or it holds no readable `meta.json`.
    case itemNotFound(String)
    /// `meta.json` exists but could not be decoded (corrupt or wrong schema).
    case malformedMeta(id: String, detail: String)
    /// A transition into a state the item's mode never reaches (#41) — a dictation sent
    /// to organization, a braindump parked in `transcribed`. Refused rather than
    /// written, so the mode/state fork stays an invariant of what is on disk.
    case unreachableState(id: String, mode: ItemMode, state: ItemState)
    /// Reprocess was asked of a mode that has none (#41): a dictation has no LLM run to
    /// start over, so there is nothing to discard and re-derive. Refused at the store
    /// rather than only hidden in the UI — it destroys artifacts before it rebuilds.
    case reprocessUnavailable(id: String, mode: ItemMode)
    /// A filesystem or encoding operation failed; `detail` is the underlying description.
    case io(String)
}

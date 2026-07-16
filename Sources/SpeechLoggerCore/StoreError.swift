import Foundation

/// The single error type the item store throws (Swift 6 typed throws). Foundation
/// errors from the filesystem are wrapped into `.io` so callers see one type.
public enum StoreError: Error, Equatable {
    /// No item directory with this id, or it holds no readable `meta.json`.
    case itemNotFound(String)
    /// `meta.json` exists but could not be decoded (corrupt or wrong schema).
    case malformedMeta(id: String, detail: String)
    /// A filesystem or encoding operation failed; `detail` is the underlying description.
    case io(String)
}

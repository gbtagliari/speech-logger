import Foundation

/// What the single menubar glyph shows. A strict priority ladder, one state wins
/// (ADR-0006, SPEC "UI"). The icon reflects app status; it does **not** signal
/// "ready" (that is the notification's job).
public enum MenubarState: Sendable, Equatable {
    /// The mic is live. Highest priority — recording always owns the glyph.
    case recording
    /// At least one item is `failed`. Persistent and easy to miss, so it outranks
    /// live processing (story 36).
    case failed
    /// Input Monitoring is not granted: the hotkey is deaf until it is fixed. Shown
    /// only when not recording/failed, so it never masks live work.
    case needsPermission
    /// At least one item is in flight (`queued` / `transcribing` / `organizing`).
    case processing
    /// Nothing to show.
    case idle

    /// Resolve the ladder from the current app conditions. Order is the contract:
    /// `recording` > `failed` > `needsPermission` > `processing` > `idle`.
    ///
    /// - Parameters:
    ///   - isRecording: the mic is currently live.
    ///   - hasFailed: any item is in the `failed` state.
    ///   - needsPermission: `CGPreflightListenEventAccess()` is false at launch.
    ///   - hasProcessing: any item is `queued` / `transcribing` / `organizing`.
    public static func resolve(
        isRecording: Bool,
        hasFailed: Bool,
        needsPermission: Bool,
        hasProcessing: Bool
    ) -> MenubarState {
        if isRecording { return .recording }
        if hasFailed { return .failed }
        if needsPermission { return .needsPermission }
        if hasProcessing { return .processing }
        return .idle
    }

    /// Convenience: derive the item-driven flags from a list of items, then resolve.
    public static func resolve(
        items: [Item],
        isRecording: Bool,
        needsPermission: Bool
    ) -> MenubarState {
        let hasFailed = items.contains { $0.state == .failed }
        let hasProcessing = items.contains {
            switch $0.state {
            case .queued, .transcribing, .organizing: return true
            case .recording, .organized, .failed, .cancelled: return false
            }
        }
        return resolve(
            isRecording: isRecording,
            hasFailed: hasFailed,
            needsPermission: needsPermission,
            hasProcessing: hasProcessing)
    }
}

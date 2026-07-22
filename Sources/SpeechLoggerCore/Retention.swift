import Foundation

/// How long an item is kept, as a pure predicate over items and a supplied instant
/// (#44, CONTEXT.md).
///
/// The two modes have opposite retention because they are opposite speech acts. A
/// **braindump** is thought being formed and is kept until deleted by hand: no cap, no
/// expiry. A **dictation** is a throwaway instruction used dozens of times a day; it is
/// kept only long enough to recover a paste that just went wrong, then swept.
///
/// The instant is supplied rather than read, so the rule is testable against a fixture
/// clock and never against the wall clock. Nothing here touches the store: deciding
/// *what* has expired is separate from *doing* the sweep (`ItemStore.sweepExpiredDictations`),
/// which is what keeps the decision a value question.
public enum Retention {
    /// The dictation window: seven days, rolling, measured from the item's creation.
    /// The window exists to recover a paste that just went wrong, not one from three
    /// weeks ago.
    public static let dictationWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Whether `item` has outlived its retention as of `instant`.
    ///
    /// Only a **terminal** dictation can expire. An in-flight one is excluded not as an
    /// age exemption but because the sweep would be deleting work the pipeline still
    /// owns — a lane holding an id whose directory just went to the Trash. Its age stops
    /// mattering the moment it settles, which is within seconds.
    public static func hasExpired(_ item: Item, at instant: Date) -> Bool {
        guard item.meta.mode == .dictation, item.state.isTerminal else { return false }
        return instant.timeIntervalSince(item.meta.created) >= dictationWindow
    }

    /// The subset of `items` that has expired as of `instant`, in the order given.
    public static func expired(among items: [Item], at instant: Date) -> [Item] {
        items.filter { hasExpired($0, at: instant) }
    }
}

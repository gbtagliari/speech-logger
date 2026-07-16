import Foundation

/// The `error` object a `failed` item carries (CONTEXT.md, ADR-0003).
public struct ItemError: Codable, Equatable, Sendable {
    public let stage: Stage
    public let reason: FailureReason
    /// Free-form context (e.g. the CLI's stderr tail). Absent when there is none.
    public let detail: String?
    public let at: Date

    public init(stage: Stage, reason: FailureReason, detail: String?, at: Date) {
        self.stage = stage
        self.reason = reason
        self.detail = detail
        self.at = at
    }
}

/// The `stoppedAt` object a `cancelled` item carries (CONTEXT.md). A cancellation
/// is not an error — it records only where the user stopped it.
public struct StoppedAt: Codable, Equatable, Sendable {
    public let stage: Stage
    public let at: Date

    public init(stage: Stage, at: Date) {
        self.stage = stage
        self.at = at
    }
}

/// The contents of `meta.json`: the explicit state and the timeline of a log item
/// (ADR-0003). It is the only file that represents `recording` and `failed`,
/// which cannot be inferred from artifact presence.
///
/// Immutable by design (matches the plain-file, temp+rename model): a transition
/// produces a *new* `ItemMeta` via the `advancing`/`failing`/`cancelling` helpers,
/// which the store then persists atomically. Nothing is mutated in place.
public struct ItemMeta: Codable, Equatable, Sendable {
    /// The migration seam if the shape ever changes (ADR-0003).
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let state: ItemState
    /// When the item (its recording) was created. The list order key.
    public let created: Date
    /// Entry time of every state reached after `recording`, keyed by the state's
    /// raw value (e.g. `"queued"`, `"organized"`). `recording`'s entry time is
    /// `created`, so it is not duplicated here.
    public let transitions: [String: Date]
    /// Recording length in seconds. Known only once recording finishes (`queued`).
    public let duration: TimeInterval?
    /// Present only when `state == failed`.
    public let error: ItemError?
    /// Present only when `state == cancelled`.
    public let stoppedAt: StoppedAt?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        state: ItemState,
        created: Date,
        transitions: [String: Date] = [:],
        duration: TimeInterval? = nil,
        error: ItemError? = nil,
        stoppedAt: StoppedAt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.created = created
        self.transitions = transitions
        self.duration = duration
        self.error = error
        self.stoppedAt = stoppedAt
    }

    /// The meta of a brand-new item at `recording`.
    public static func recording(created: Date) -> ItemMeta {
        ItemMeta(state: .recording, created: created)
    }

    /// The timestamp at which `state` was entered (`created` for `recording`).
    public func timestamp(of state: ItemState) -> Date? {
        state == .recording ? created : transitions[state.rawValue]
    }

    /// A new meta advanced to a non-terminal happy-path state at `at`, optionally
    /// setting the recording `duration` (set on the move to `queued`). Clears any
    /// prior error/stoppedAt, since the happy path is being (re)entered.
    public func advancing(to next: ItemState, at: Date, duration: TimeInterval? = nil) -> ItemMeta {
        ItemMeta(
            schemaVersion: schemaVersion,
            state: next,
            created: created,
            transitions: transitions.merging([next.rawValue: at]) { _, new in new },
            duration: duration ?? self.duration,
            error: nil,
            stoppedAt: nil
        )
    }

    /// A new meta at `failed`, carrying the error and stamping the `failed` entry time.
    public func failing(stage: Stage, reason: FailureReason, detail: String?, at: Date) -> ItemMeta {
        ItemMeta(
            schemaVersion: schemaVersion,
            state: .failed,
            created: created,
            transitions: transitions.merging([ItemState.failed.rawValue: at]) { _, new in new },
            duration: duration,
            error: ItemError(stage: stage, reason: reason, detail: detail, at: at),
            stoppedAt: nil
        )
    }

    /// A new meta at `cancelled`, recording where the user stopped it.
    public func cancelling(stage: Stage, at: Date) -> ItemMeta {
        ItemMeta(
            schemaVersion: schemaVersion,
            state: .cancelled,
            created: created,
            transitions: transitions.merging([ItemState.cancelled.rawValue: at]) { _, new in new },
            duration: duration,
            error: nil,
            stoppedAt: StoppedAt(stage: stage, at: at)
        )
    }
}

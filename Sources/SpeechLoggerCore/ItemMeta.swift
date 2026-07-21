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
    /// The migration seam if the shape ever changes (ADR-0003). Bumped to 2 by the
    /// arrival of `mode` (#41); version 1 items need no migration pass, since an
    /// absent `mode` reads as `braindump`, which is what every one of them is.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let state: ItemState
    /// Which speech act this item is. Absent on disk reads as `braindump` (#41).
    public let mode: ItemMode
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
        mode: ItemMode = .braindump,
        created: Date,
        transitions: [String: Date] = [:],
        duration: TimeInterval? = nil,
        error: ItemError? = nil,
        stoppedAt: StoppedAt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.mode = mode
        self.created = created
        self.transitions = transitions
        self.duration = duration
        self.error = error
        self.stoppedAt = stoppedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, state, mode, created, transitions, duration, error, stoppedAt
    }

    /// Hand-written so an absent `mode` decodes as `braindump`. Swift's synthesized
    /// decoding ignores property defaults and would reject every schema-version-1
    /// `meta.json` on disk, forcing exactly the migration pass this default avoids.
    /// Every other key keeps the synthesized strictness: only `mode` is optional.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        state = try container.decode(ItemState.self, forKey: .state)
        mode = try container.decodeIfPresent(ItemMode.self, forKey: .mode) ?? .braindump
        created = try container.decode(Date.self, forKey: .created)
        transitions = try container.decode([String: Date].self, forKey: .transitions)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        error = try container.decodeIfPresent(ItemError.self, forKey: .error)
        stoppedAt = try container.decodeIfPresent(StoppedAt.self, forKey: .stoppedAt)
    }

    /// The meta of a brand-new item at `recording`.
    public static func recording(created: Date, mode: ItemMode = .braindump) -> ItemMeta {
        ItemMeta(state: .recording, mode: mode, created: created)
    }

    /// The timestamp at which `state` was entered (`created` for `recording`).
    public func timestamp(of state: ItemState) -> Date? {
        state == .recording ? created : transitions[state.rawValue]
    }

    /// The stage this item died at, or `nil` if it is not dead — the single place that
    /// knows a `failed` item carries its stage under `error` and a `cancelled` one under
    /// `stoppedAt`. Everything that reasons about running an item again (retry's resume
    /// stage, both `isRetryable` and `isReprocessable`) reads it from here rather than
    /// re-deriving the same two-arm switch.
    public var deathStage: Stage? {
        switch state {
        case .failed: return error?.stage
        case .cancelled: return stoppedAt?.stage
        case .recording, .queued, .transcribing, .transcribed, .organizing, .organized: return nil
        }
    }

    /// A new meta advanced to a non-terminal happy-path state at `at`, optionally
    /// setting the recording `duration` (set on the move to `queued`). Clears any
    /// prior error/stoppedAt, since the happy path is being (re)entered.
    ///
    /// Like `failing` and `cancelling`, it stamps `currentSchemaVersion` rather than
    /// carrying the decoded one forward: the bytes this produces *are* the current
    /// shape, so a version-1 item upgrades the first time it transitions. Propagating
    /// the old number would write a `mode` key under a version that predates it,
    /// leaving the seam unable to tell the two shapes apart.
    public func advancing(to next: ItemState, at: Date, duration: TimeInterval? = nil) -> ItemMeta {
        ItemMeta(
            schemaVersion: Self.currentSchemaVersion,
            state: next,
            mode: mode,
            created: created,
            transitions: transitions.merging([next.rawValue: at]) { _, new in new },
            duration: duration ?? self.duration,
            error: nil,
            stoppedAt: nil
        )
    }

    /// A new meta under a different mode, for the one moment a mode changes: the end
    /// of a recording, where the gesture finally says which speech act it was (#42).
    /// Everything else about the item is untouched — it is a label, not a transition.
    public func labeled(as mode: ItemMode) -> ItemMeta {
        ItemMeta(
            schemaVersion: Self.currentSchemaVersion,
            state: state,
            mode: mode,
            created: created,
            transitions: transitions,
            duration: duration,
            error: error,
            stoppedAt: stoppedAt
        )
    }

    /// A new meta at `failed`, carrying the error and stamping the `failed` entry time.
    public func failing(stage: Stage, reason: FailureReason, detail: String?, at: Date) -> ItemMeta {
        ItemMeta(
            schemaVersion: Self.currentSchemaVersion,
            state: .failed,
            mode: mode,
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
            schemaVersion: Self.currentSchemaVersion,
            state: .cancelled,
            mode: mode,
            created: created,
            transitions: transitions.merging([ItemState.cancelled.rawValue: at]) { _, new in new },
            duration: duration,
            error: nil,
            stoppedAt: StoppedAt(stage: stage, at: at)
        )
    }
}

import Foundation

/// Which speech act an item is (ADR-0007, #40). Two modes, not two moods: a
/// **braindump** is a thought being formed, which earns the two LLM passes and lands
/// in the log to be collected later; a **dictation** is a short throwaway instruction,
/// raw Whisper output with no LLM in its path.
///
/// Absent from `meta.json` reads as `braindump`, so items written before the mode
/// existed keep working with no migration pass — the schema seam ADR-0003 reserved.
public enum ItemMode: String, Codable, Sendable, CaseIterable {
    case braindump
    case dictation

    /// Whether an item in this mode can ever be in `state`.
    ///
    /// The two happy paths fork after `transcribing` and never cross. Organization is
    /// braindump-only, so `transcribed` is the dictation terminal (the transcript *is*
    /// the output) and `organizing`/`organized` are unreachable for it. Everything
    /// before the fork, and both off-ramps, are shared.
    ///
    /// The single home for that rule: the store refuses to persist a state its item's
    /// mode does not reach, so "a braindump never rests in `transcribed`" is enforced
    /// where state becomes durable rather than trusted to every caller.
    public func reaches(_ state: ItemState) -> Bool {
        switch state {
        case .transcribed: return self == .dictation
        case .organizing, .organized: return self == .braindump
        case .recording, .queued, .transcribing, .failed, .cancelled: return true
        }
    }
}

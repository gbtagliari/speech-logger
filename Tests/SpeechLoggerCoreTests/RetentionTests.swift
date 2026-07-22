import Foundation
import Testing

@testable import SpeechLoggerCore

/// Retention as a pure predicate over items and a supplied instant (#44): dictations
/// expire at seven days, braindumps never do, and an item still in flight is never
/// swept out from under the pipeline. Every case is judged against a fixture clock —
/// nothing here reads the wall clock.
struct RetentionTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        _ id: String, mode: ItemMode, state: ItemState, created: Date
    ) -> Item {
        Item(id: id, meta: ItemMeta(state: state, mode: mode, created: created))
    }

    private var window: TimeInterval { Retention.dictationWindow }

    @Test("a dictation older than the window has expired")
    func oldDictationExpires() {
        let dictation = item("d", mode: .dictation, state: .transcribed, created: base)
        #expect(Retention.hasExpired(dictation, at: base.addingTimeInterval(window + 1)))
    }

    @Test("a dictation inside the window has not")
    func youngDictationSurvives() {
        let dictation = item("d", mode: .dictation, state: .transcribed, created: base)
        #expect(!Retention.hasExpired(dictation, at: base.addingTimeInterval(window - 1)))
    }

    @Test("the window is exactly seven days, and its edge expires")
    func windowIsSevenDays() {
        #expect(window == 7 * 24 * 60 * 60)
        let dictation = item("d", mode: .dictation, state: .transcribed, created: base)
        #expect(Retention.hasExpired(dictation, at: base.addingTimeInterval(window)))
    }

    @Test("a braindump of any age never expires: its retention is manual only")
    func braindumpNeverExpires() {
        let states: [ItemState] = [.organized, .failed, .cancelled]
        for state in states {
            let braindump = item("b", mode: .braindump, state: state, created: base)
            #expect(!Retention.hasExpired(braindump, at: base.addingTimeInterval(window * 52)))
        }
    }

    @Test("an in-flight dictation is never expired, however old the clock says it is")
    func inFlightDictationSurvives() {
        let states: [ItemState] = [.recording, .queued, .transcribing]
        for state in states {
            let dictation = item("d", mode: .dictation, state: state, created: base)
            #expect(!Retention.hasExpired(dictation, at: base.addingTimeInterval(window * 10)))
        }
    }

    @Test("a dead dictation expires like a finished one: both are terminal")
    func deadDictationExpires() {
        let states: [ItemState] = [.transcribed, .failed, .cancelled]
        for state in states {
            let dictation = item("d", mode: .dictation, state: state, created: base)
            #expect(Retention.hasExpired(dictation, at: base.addingTimeInterval(window + 1)))
        }
    }

    @Test("the sweep selects exactly the expired dictations, in list order")
    func expiredSelection() {
        let items = [
            item("old-dictation", mode: .dictation, state: .transcribed, created: base),
            item("fresh-dictation", mode: .dictation, state: .transcribed,
                created: base.addingTimeInterval(window)),
            item("old-braindump", mode: .braindump, state: .organized, created: base),
            item("live-dictation", mode: .dictation, state: .queued, created: base),
        ]
        let expired = Retention.expired(among: items, at: base.addingTimeInterval(window + 1))
        #expect(expired.map(\.id) == ["old-dictation"])
    }
}

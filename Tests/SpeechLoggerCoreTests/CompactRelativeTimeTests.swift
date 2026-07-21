import Foundation
import Testing

@testable import SpeechLoggerCore

/// The panel's compact "how long ago" stamp, pt-BR and terse to fit a row's right
/// edge, so items are told apart at a glance.
struct CompactRelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("under a minute reads as agora")
    func underAMinute() {
        #expect(CompactRelativeTime.text(from: now.addingTimeInterval(-30), now: now) == "agora")
    }

    @Test("minutes read as N min")
    func minutes() {
        #expect(CompactRelativeTime.text(from: now.addingTimeInterval(-120), now: now) == "2 min")
    }

    @Test("hours read as N h")
    func hours() {
        #expect(CompactRelativeTime.text(from: now.addingTimeInterval(-3 * 3600), now: now) == "3 h")
    }

    @Test("a day or more reads as N d")
    func days() {
        #expect(CompactRelativeTime.text(from: now.addingTimeInterval(-2 * 86400), now: now) == "2 d")
    }

    @Test("a future or same instant is agora, never negative")
    func clampsToNow() {
        #expect(CompactRelativeTime.text(from: now.addingTimeInterval(60), now: now) == "agora")
    }
}

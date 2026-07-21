import Foundation
import Testing

@testable import SpeechLoggerCore

/// The mode/state relation (#41, ADR-0007): which states each speech act can ever be
/// in. The two happy paths fork after `transcribing` and never cross, and this is the
/// single place that rule is stated — the store reads it to refuse a write.
struct ItemModeTests {
    @Test("a braindump never rests in transcribed: its happy path runs through organization")
    func braindumpNeverTranscribed() {
        #expect(!ItemMode.braindump.reaches(.transcribed))
    }

    @Test(
        "a dictation never reaches organization: there is no LLM in its path",
        arguments: [ItemState.organizing, .organized])
    func dictationNeverOrganizes(state: ItemState) {
        #expect(!ItemMode.dictation.reaches(state))
    }

    @Test("a dictation rests in transcribed, a braindump in organized")
    func eachModeReachesItsOwnTerminal() {
        #expect(ItemMode.dictation.reaches(.transcribed))
        #expect(ItemMode.braindump.reaches(.organized))
    }

    @Test(
        "everything before the fork and both off-ramps are shared",
        arguments: [ItemState.recording, .queued, .transcribing, .failed, .cancelled])
    func sharedStates(state: ItemState) {
        #expect(ItemMode.braindump.reaches(state))
        #expect(ItemMode.dictation.reaches(state))
    }
}

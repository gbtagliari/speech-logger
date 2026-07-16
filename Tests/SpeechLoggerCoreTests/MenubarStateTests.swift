import Foundation
import Testing

@testable import SpeechLoggerCore

/// The menubar glyph is a strict priority ladder, one state wins
/// (ADR-0006): `recording` > `failed` > `needsPermission` > `processing` > `idle`.
struct MenubarStateTests {
    @Test("recording outranks everything, even a failed item")
    func recordingWins() {
        #expect(
            MenubarState.resolve(
                isRecording: true, hasFailed: true, needsPermission: true, hasProcessing: true)
                == .recording)
    }

    @Test("a failed item outranks a missing permission and live processing")
    func failedOutranksPermissionAndProcessing() {
        #expect(
            MenubarState.resolve(
                isRecording: false, hasFailed: true, needsPermission: true, hasProcessing: true)
                == .failed)
    }

    @Test("needs-permission outranks processing when nothing failed")
    func permissionOutranksProcessing() {
        #expect(
            MenubarState.resolve(
                isRecording: false, hasFailed: false, needsPermission: true, hasProcessing: true)
                == .needsPermission)
    }

    @Test("processing shows when an item is in flight and nothing higher applies")
    func processingShows() {
        #expect(
            MenubarState.resolve(
                isRecording: false, hasFailed: false, needsPermission: false, hasProcessing: true)
                == .processing)
    }

    @Test("idle is the floor")
    func idleFloor() {
        #expect(
            MenubarState.resolve(
                isRecording: false, hasFailed: false, needsPermission: false, hasProcessing: false)
                == .idle)
    }

    // MARK: - Deriving flags from items

    @Test("a queued item counts as processing")
    func queuedIsProcessing() throws {
        let items = [Item(id: "a", meta: .recording(created: Date()).advancing(to: .queued, at: Date()))]
        #expect(
            MenubarState.resolve(items: items, isRecording: false, needsPermission: false)
                == .processing)
    }

    @Test("organized and cancelled items alone leave the icon idle")
    func terminalNonFailedItemsAreIdle() {
        let now = Date()
        let organized = Item(
            id: "a",
            meta: ItemMeta(state: .organized, created: now))
        let cancelled = Item(
            id: "b",
            meta: ItemMeta(state: .cancelled, created: now))
        #expect(
            MenubarState.resolve(
                items: [organized, cancelled], isRecording: false, needsPermission: false)
                == .idle)
    }

    @Test("a failed item in the list drives the failed glyph")
    func failedItemDrivesGlyph() {
        let failed = Item(id: "a", meta: ItemMeta(state: .failed, created: Date()))
        #expect(
            MenubarState.resolve(items: [failed], isRecording: false, needsPermission: false)
                == .failed)
    }
}

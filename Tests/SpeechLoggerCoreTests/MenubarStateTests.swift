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

    // MARK: - Deriving flags from items and preflight

    /// A preflight report with one check knocked out, for the tier tests below.
    private func preflight(failing: PreflightCheck?) -> PreflightReport {
        PreflightReport(
            results: PreflightCheck.allCases.map {
                PreflightResult(check: $0, isSatisfied: $0 != failing)
            })
    }

    @Test("a queued item counts as processing")
    func queuedIsProcessing() throws {
        let items = [Item(id: "a", meta: .recording(created: Date()).advancing(to: .queued, at: Date()))]
        #expect(
            MenubarState.resolve(items: items, isRecording: false, preflight: .satisfied)
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
                items: [organized, cancelled], isRecording: false, preflight: .satisfied)
                == .idle)
    }

    @Test("a failed item in the list drives the failed glyph")
    func failedItemDrivesGlyph() {
        let failed = Item(id: "a", meta: ItemMeta(state: .failed, created: Date()))
        #expect(
            MenubarState.resolve(items: [failed], isRecording: false, preflight: .satisfied)
                == .failed)
    }

    @Test("a failed dictation climbs the ladder like any other failure")
    func failedDictationDrivesGlyph() {
        // The ladder is mode-agnostic with no exception (#44): suppressing a dictation
        // here would need the mode-aware icon ADR-0007 rejects, and the failure tier is
        // the mode's only failure signal — it has no other visual surface.
        let failed = Item(
            id: "a", meta: ItemMeta(state: .failed, mode: .dictation, created: Date()))
        #expect(
            MenubarState.resolve(items: [failed], isRecording: false, preflight: .satisfied)
                == .failed)
    }

    @Test("a finished dictation alone leaves the icon idle")
    func transcribedDictationIsIdle() {
        let done = Item(
            id: "a", meta: ItemMeta(state: .transcribed, mode: .dictation, created: Date()))
        #expect(
            MenubarState.resolve(items: [done], isRecording: false, preflight: .satisfied) == .idle)
    }

    // MARK: - Preflight tiers

    /// Preflight failures surface as the aggregate `failed` icon tier. With no items
    /// at all, a missing binary is what raises it.
    @Test(
        "a missing prerequisite raises the failed glyph with no items in the log",
        arguments: [PreflightCheck.mlxWhisper, .ffmpeg, .claude, .claudeLogin, .whisperModel])
    func missingPrerequisiteDrivesFailedGlyph(check: PreflightCheck) {
        #expect(
            MenubarState.resolve(items: [], isRecording: false, preflight: preflight(failing: check))
                == .failed)
    }

    @Test("a denied Input Monitoring drives the lock, not the failed glyph")
    func deniedPermissionDrivesLock() {
        #expect(
            MenubarState.resolve(
                items: [], isRecording: false, preflight: preflight(failing: .inputMonitoring))
                == .needsPermission)
    }

    @Test("a satisfied preflight leaves an empty log idle")
    func satisfiedPreflightIsIdle() {
        #expect(MenubarState.resolve(items: [], isRecording: false, preflight: .satisfied) == .idle)
    }

    /// The hotkey is never blocked (SPEC), so a recording still owns the glyph while a
    /// prerequisite is missing — the item will land as a retryable `failed` on its own.
    @Test("recording still outranks a missing prerequisite")
    func recordingOutranksPreflight() {
        #expect(
            MenubarState.resolve(
                items: [], isRecording: true, preflight: preflight(failing: .mlxWhisper))
                == .recording)
    }
}

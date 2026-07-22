import Foundation
import Testing

@testable import SpeechLoggerCore

/// The hotkey detection logic is the single most bug-prone seam in the app: the
/// obvious "any other modifier held?" test is *always true* on the raw flag word,
/// so a detector written the natural way is silent across every real event
/// (ADR-0004, `global-hotkey-capture-macos.md`). These tests drive synthetic
/// `flagsChanged` events using the exact raw flag words observed on-device, so a
/// regression that drops the `0x207F` mask fails here loudly.
///
/// Every event is (keyCode, rawFlags): a press and a release are both
/// `flagsChanged`; direction comes from the device bit, not the event type. The
/// braindump cases below are the regression that matters for #42 — the grammar grew
/// a second mode without moving the toggle it already had.
struct HotkeyDetectorTests {
    // Raw flag words observed on-device (research doc's decomposition table).
    private static let rOptDown: UInt64 = 0x0008_0140  // right-Option pressed
    private static let allReleased: UInt64 = 0x0000_0100  // every modifier up
    private static let rShiftROptDown: UInt64 = 0x000A_0144  // right-Shift + right-Option
    private static let lOptDown: UInt64 = 0x0008_0120  // left-Option pressed

    private static let rOptKeyCode: Int64 = 61
    private static let lOptKeyCode: Int64 = 58
    private static let rShiftKeyCode: Int64 = 60

    // MARK: - The trap: the mask is load-bearing

    @Test("a double-tap of right-Option within the window starts a recording on the second press")
    func doubleTapFires() {
        var detector = HotkeyDetector(window: 0.30)
        // First tap: press then release.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 10.00, isRecording: false) == nil)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 10.05, isRecording: false) == nil)
        // Second press within the window starts.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 10.20, isRecording: false) == .start)
    }

    @Test("the raw flag word's general + noncoalesced bits do not read as a foreign modifier")
    func rawFlagWordIsNotMistakenForCombo() {
        // 0x00080140 & ~0x40 == 0x00080100 != 0: a detector that tests the *raw*
        // word treats a lone right-Option as a combo and never fires. Masking to
        // 0x207F first is what makes this pass. Two clean taps must start a recording.
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 1.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 1.05, isRecording: false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 1.20, isRecording: false) == .start)
    }

    // MARK: - Single tap and the window boundary

    @Test("a lone tap never fires")
    func singleTapDoesNotFire() {
        var detector = HotkeyDetector(window: 0.30)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 5.00, isRecording: false) == nil)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 5.10, isRecording: false) == nil)
    }

    @Test("a second tap past the window does not fire but re-arms as a new first tap")
    func slowSecondTapRearms() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        // 0.40 > 0.30: too slow, no fire.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.40, isRecording: false) == nil)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.45, isRecording: false)
        // But that slow tap became the new first tap: a prompt follow-up fires.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.55, isRecording: false) == .start)
    }

    @Test("the window boundary is inclusive")
    func windowBoundaryInclusive() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        // Exactly at the window.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.30, isRecording: false) == .start)
    }

    // MARK: - Rising edge only

    @Test("a held key (a second press event with no release between) collapses to one tap")
    func heldKeyDoesNotDoubleFire() {
        var detector = HotkeyDetector(window: 0.30)
        // Two consecutive down events with no release: key repeat / stuck flag.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false) == nil)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.10, isRecording: false) == nil)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20, isRecording: false) == nil)
    }

    // MARK: - Foreign keys and combos

    @Test("a left-Option double-tap is ignored (wrong keyCode)")
    func leftOptionIgnored() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.lOptKeyCode, flags: Self.lOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.lOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        #expect(detector.handle(keyCode: Self.lOptKeyCode, flags: Self.lOptDown, now: 0.20, isRecording: false) == nil)
    }

    @Test("right-Option pressed as part of a combo resets the timer and never fires")
    func comboResetsTimer() {
        var detector = HotkeyDetector(window: 0.30)
        // A clean first tap.
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        // Second press is really ⇧⌥ (device bits 0x44): not our gesture.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rShiftROptDown, now: 0.15, isRecording: false) == nil)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.20, isRecording: false)
        // The timer was reset, so the next lone tap is a first tap, not a fire.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.25, isRecording: false) == nil)
    }

    @Test("a foreign modifier tapping between the two taps is ignored, the timer keeps running")
    func foreignModifierBetweenTapsIgnored() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        // A right-Shift press/release in between: different keyCode, ignored.
        _ = detector.handle(keyCode: Self.rShiftKeyCode, flags: 0x0002_0104, now: 0.10, isRecording: false)
        _ = detector.handle(keyCode: Self.rShiftKeyCode, flags: Self.allReleased, now: 0.12, isRecording: false)
        // Our second right-Option tap still fires, within the original window.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20, isRecording: false) == .start)
    }

    // MARK: - After firing

    @Test("after firing, a third tap does not immediately re-fire")
    func fireResetsState() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05, isRecording: false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20, isRecording: false) == .start)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.25, isRecording: true)
        // A single tap right after the fire is only a first tap again.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.35, isRecording: true) == nil)
    }

    // MARK: - The mode threshold (#42)

    @Test("a quick release labels the recording a braindump: it keeps running until a second gesture")
    func quickReleaseIsBraindumpToggle() {
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        #expect(startsRecording(&detector, at: 0.00) == .start)
        // Released 100 ms in, well under T: a toggle. Nothing stops here.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.30, isRecording: true) == nil)
        // The mic is still open minutes later; the next double-tap is what ends it.
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 60.00, isRecording: true)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 60.05, isRecording: true)
        #expect(
            detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 60.20, isRecording: true)
                == .stop(.braindump))
    }

    @Test("holding tap 2 past T labels the recording a dictation, and the release stops it")
    func heldTapTwoIsPushToTalk() {
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        #expect(startsRecording(&detector, at: 0.00) == .start)
        // Still down 2 s later: push-to-talk, and the release is the stop.
        #expect(
            detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 2.20, isRecording: true)
                == .stop(.dictation))
    }

    @Test("the mode threshold is checked either side of T")
    func thresholdBoundary() {
        // Tap 2 lands at 0.20 in both runs; only the release time differs.
        var justUnder = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        _ = startsRecording(&justUnder, at: 0.00)
        #expect(
            justUnder.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.449, isRecording: true) == nil)

        var atThreshold = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        _ = startsRecording(&atThreshold, at: 0.00)
        #expect(
            atThreshold.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.45, isRecording: true)
                == .stop(.dictation))
    }

    @Test("T is injectable, like the double-tap window")
    func thresholdIsInjectable() {
        // The same 0.30 s hold reads as a dictation under a 250 ms T and as a
        // braindump under a 500 ms one — the on-device tuning seam.
        var quick = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        _ = startsRecording(&quick, at: 0.00)
        #expect(
            quick.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.50, isRecording: true)
                == .stop(.dictation))

        var patient = HotkeyDetector(window: 0.30, holdThreshold: 0.50)
        _ = startsRecording(&patient, at: 0.00)
        #expect(patient.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.50, isRecording: true) == nil)
    }

    @Test(
        "recording starts on tap 2 in both modes, before the mode is known",
        arguments: [(0.05, HotkeyGesture?.none), (5.00, .stop(.dictation))])
    func recordingStartsOnTapTwoInBothModes(heldFor: TimeInterval, thenEnds: HotkeyGesture?) {
        // The same three events open the mic in both modes; only the fourth — how long
        // tap 2 stayed down — separates them. What waits for `T` is the label, so the
        // identical `.start` has to come out first whichever mode this turns into.
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        #expect(startsRecording(&detector, at: 0.00) == .start)
        #expect(
            detector.handle(
                keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.20 + heldFor, isRecording: true)
                == thenEnds)
    }

    // MARK: - A hold is not a gesture on its own

    @Test("a hold with no preceding double-tap does nothing")
    func loneHoldDoesNothing() {
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        // One press, held three seconds, released. Right-Option is a modifier people
        // hold for other reasons; only the double-tap arms the grammar.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00, isRecording: false) == nil)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 3.00, isRecording: false) == nil)
    }

    // MARK: - Recording wins the key

    @Test("while recording, a double-tap only stops: it never starts a second recording")
    func gestureWhileRecordingOnlyStops() {
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        _ = startsRecording(&detector, at: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.25, isRecording: true)

        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 4.00, isRecording: true)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 4.05, isRecording: true)
        #expect(
            detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 4.20, isRecording: true)
                == .stop(.braindump))
    }

    @Test("while recording, holding tap 2 of the stopping gesture still only stops")
    func heldGestureWhileRecordingOnlyStops() {
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        _ = startsRecording(&detector, at: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.25, isRecording: true)

        // The stop fires on the press, so the hold has nothing left to label: the
        // grammar applies from idle only.
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 4.00, isRecording: true)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 4.05, isRecording: true)
        #expect(
            detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 4.20, isRecording: true)
                == .stop(.braindump))
        // Released a second later, long past T: no second verdict.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 5.20, isRecording: false) == nil)
    }

    // MARK: - The coordinator's `isRecording` is the truth

    @Test("a recording that never started leaves the grammar at idle, not owing a stop")
    func refusedRecordingResetsTheGrammar() {
        // An unusable microphone refuses the start (#45), so `isRecording` stays
        // false. The release must not be read as a dictation's stop, and the next
        // double-tap must start cleanly rather than land on a phantom recording.
        var detector = HotkeyDetector(window: 0.30, holdThreshold: 0.25)
        #expect(startsRecording(&detector, at: 0.00) == .start)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 2.00, isRecording: false) == nil)

        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 9.00, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 9.05, isRecording: false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 9.20, isRecording: false) == .start)
    }

    // MARK: - Helpers

    /// Drive a clean double-tap from idle, leaving tap 2 **held** at `at + 0.20`.
    /// Returns the gesture tap 2 produced.
    private func startsRecording(_ detector: inout HotkeyDetector, at: TimeInterval) -> HotkeyGesture? {
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: at, isRecording: false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: at + 0.05, isRecording: false)
        return detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: at + 0.20, isRecording: false)
    }
}

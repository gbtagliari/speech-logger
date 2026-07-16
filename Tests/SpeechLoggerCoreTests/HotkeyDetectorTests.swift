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
/// `flagsChanged`; direction comes from the device bit, not the event type.
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

    @Test("a double-tap of right-Option within the window fires exactly once, on the second press")
    func doubleTapFires() {
        var detector = HotkeyDetector(window: 0.30)
        // First tap: press then release.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 10.00) == false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 10.05) == false)
        // Second press within the window fires.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 10.20) == true)
    }

    @Test("the raw flag word's general + noncoalesced bits do not read as a foreign modifier")
    func rawFlagWordIsNotMistakenForCombo() {
        // 0x00080140 & ~0x40 == 0x00080100 != 0: a detector that tests the *raw*
        // word treats a lone right-Option as a combo and never fires. Masking to
        // 0x207F first is what makes this pass. Two clean taps must fire.
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 1.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 1.05)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 1.20) == true)
    }

    // MARK: - Single tap and the window boundary

    @Test("a lone tap never fires")
    func singleTapDoesNotFire() {
        var detector = HotkeyDetector(window: 0.30)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 5.00) == false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 5.10) == false)
    }

    @Test("a second tap past the window does not fire but re-arms as a new first tap")
    func slowSecondTapRearms() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05)
        // 0.40 > 0.30: too slow, no fire.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.40) == false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.45)
        // But that slow tap became the new first tap: a prompt follow-up fires.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.55) == true)
    }

    @Test("the window boundary is inclusive")
    func windowBoundaryInclusive() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05)
        // Exactly at the window.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.30) == true)
    }

    // MARK: - Rising edge only

    @Test("a held key (a second press event with no release between) collapses to one tap")
    func heldKeyDoesNotDoubleFire() {
        var detector = HotkeyDetector(window: 0.30)
        // Two consecutive down events with no release: key repeat / stuck flag.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00) == false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.10) == false)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20) == false)
    }

    // MARK: - Foreign keys and combos

    @Test("a left-Option double-tap is ignored (wrong keyCode)")
    func leftOptionIgnored() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.lOptKeyCode, flags: Self.lOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.lOptKeyCode, flags: Self.allReleased, now: 0.05)
        #expect(detector.handle(keyCode: Self.lOptKeyCode, flags: Self.lOptDown, now: 0.20) == false)
    }

    @Test("right-Option pressed as part of a combo resets the timer and never fires")
    func comboResetsTimer() {
        var detector = HotkeyDetector(window: 0.30)
        // A clean first tap.
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05)
        // Second press is really ⇧⌥ (device bits 0x44): not our gesture.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rShiftROptDown, now: 0.15) == false)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.20)
        // The timer was reset, so the next lone tap is a first tap, not a fire.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.25) == false)
    }

    @Test("a foreign modifier tapping between the two taps is ignored, the timer keeps running")
    func foreignModifierBetweenTapsIgnored() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05)
        // A right-Shift press/release in between: different keyCode, ignored.
        _ = detector.handle(keyCode: Self.rShiftKeyCode, flags: 0x0002_0104, now: 0.10)
        _ = detector.handle(keyCode: Self.rShiftKeyCode, flags: Self.allReleased, now: 0.12)
        // Our second right-Option tap still fires, within the original window.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20) == true)
    }

    // MARK: - After firing

    @Test("after firing, a third tap does not immediately re-fire")
    func fireResetsState() {
        var detector = HotkeyDetector(window: 0.30)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.00)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.05)
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.20) == true)
        _ = detector.handle(keyCode: Self.rOptKeyCode, flags: Self.allReleased, now: 0.25)
        // A single tap right after the fire is only a first tap again.
        #expect(detector.handle(keyCode: Self.rOptKeyCode, flags: Self.rOptDown, now: 0.35) == false)
    }
}

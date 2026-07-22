import Testing

@testable import SpeechLoggerCore

/// The auto-paste guard (#43): a boolean over app-activation events, not a deadline.
/// The whole decision is exercised here as a pure value — no window server, no
/// workspace notifications, no keystroke — which is the point of keeping the
/// observation outside the seam.
struct AutoPasteGuardTests {
    // MARK: - Arming

    @Test("it starts unarmed, and the key release arms it")
    func armsOnRelease() {
        var sut = AutoPasteGuard()
        #expect(!sut.isArmed)
        sut.arm()
        #expect(sut.isArmed)
    }

    @Test("armed with the transcript ready and the grant in place, it pastes")
    func pastesWhileArmed() {
        var sut = AutoPasteGuard()
        sut.arm()
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
    }

    @Test("a transcript with no release behind it never pastes")
    func neverArmedNeverPastes() {
        let sut = AutoPasteGuard()
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
    }

    // MARK: - Disarming

    @Test("any app activation disarms it, and the transcript then only sounds")
    func activationDisarms() {
        var sut = AutoPasteGuard()
        sut.arm()
        sut.appDidActivate()
        #expect(!sut.isArmed)
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
    }

    /// The accepted consequence: this app activating itself disarms too, so clicking
    /// the menubar between release and paste kills the auto-paste. The guard cannot
    /// tell whose activation it is, and deliberately does not try — an activation is
    /// an activation.
    @Test("the app's own activation disarms like any other")
    func ownActivationDisarms() {
        var sut = AutoPasteGuard()
        sut.arm()
        sut.appDidActivate()
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
    }

    @Test("further activations while disarmed change nothing")
    func staysDisarmed() {
        var sut = AutoPasteGuard()
        sut.arm()
        sut.appDidActivate()
        sut.appDidActivate()
        #expect(!sut.isArmed)
    }

    @Test("the next release re-arms after a disarm")
    func rearmsAfterDisarm() {
        var sut = AutoPasteGuard()
        sut.arm()
        sut.appDidActivate()
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
        sut.arm()
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
    }

    // MARK: - Trust

    /// Re-checked immediately before posting, because the grant can be revoked between
    /// launch and here. Withheld, the text still did not land, so it takes the same
    /// exit as a disarmed guard.
    @Test("armed but untrusted posts nothing and sounds")
    func untrustedDoesNotPaste() {
        var sut = AutoPasteGuard()
        sut.arm()
        #expect(sut.transcriptReady(isTrusted: false) == .sound)
    }

    @Test("a withheld grant does not disarm: the next transcript pastes once it is back")
    func trustIsNotStickiness() {
        var sut = AutoPasteGuard()
        sut.arm()
        #expect(sut.transcriptReady(isTrusted: false) == .sound)
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
    }

    // MARK: - More than one dictation in flight

    /// The state machine in the spec is drawn for one dictation, but the mode is built
    /// for two-second commands and a transcript takes ~2.5 s, so two in flight is
    /// ordinary use. Reading the guard must not clear it, or every dictation after the
    /// first would silently lose its paste.
    @Test("two dictations released back to back both paste, with no activation between")
    func backToBackDictationsBothPaste() {
        var sut = AutoPasteGuard()
        sut.arm()  // first release
        sut.arm()  // second release, while the first is still transcribing
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
    }

    @Test("an activation while two are in flight suppresses both")
    func activationSuppressesEveryInFlightDictation() {
        var sut = AutoPasteGuard()
        sut.arm()
        sut.arm()
        sut.appDidActivate()
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
        #expect(sut.transcriptReady(isTrusted: true) == .sound)
    }

    /// A hold below the duration floor, or a silent one, is discarded and never
    /// produces a transcript — so its arming is never read. It must not desynchronise
    /// the next dictation, which is exactly what per-item bookkeeping would risk here.
    @Test("an arming that never produced a transcript is harmlessly overwritten")
    func staleArmingIsHarmless() {
        var sut = AutoPasteGuard()
        sut.arm()  // a hold that turns out too short: discarded, no transcript
        sut.appDidActivate()
        sut.arm()  // a real dictation, released at the cursor
        #expect(sut.transcriptReady(isTrusted: true) == .paste)
    }
}

import Testing

@testable import SpeechLoggerCore

/// The watchdog is the whole recovery policy for a capture whose engine will not stay
/// bound to the device (#63): it reads two signals and answers with one of three moves.
///
/// It exists as a value precisely so the policy replays without a Bluetooth headset —
/// the device the ticket was measured on needs an HFP link coming up to reproduce
/// anything, and the decision itself is arithmetic.
struct CaptureWatchdogTests {
    private let watchdog = CaptureWatchdog()

    @Test("an engine that stopped under the capture is restarted")
    func stoppedEngineRestarts() {
        #expect(
            watchdog.verdict(
                engineIsRunning: false, hasReceivedAudio: true, sinceLastFrame: 0,
                restarts: 0) == .restart)
    }

    @Test("a running engine with audio arriving is left alone")
    func healthyCaptureIsLeftAlone() {
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: true, sinceLastFrame: 0,
                restarts: 0) == .keepRecording)
    }

    // MARK: - The second signal: frames that never arrive (#63, shape 2)

    @Test("an engine that stays running and delivers nothing is restarted")
    func silentRunningEngineRestarts() {
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: false, sinceLastFrame: 0.5,
                restarts: 0) == .restart)
    }

    @Test("a device still opening inside the opening window is given the time")
    func openingWindowIsAllowed() {
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: false, sinceLastFrame: 0.3,
                restarts: 0) == .keepRecording)
    }

    @Test("once audio has flowed, one late buffer is not a stall")
    func flowingCaptureToleratesALateBuffer() {
        // 4096 frames at 16 kHz is a 256 ms buffer period, so the opening window would
        // read a single late buffer mid-braindump as a dead device.
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: true, sinceLastFrame: 0.5,
                restarts: 0) == .keepRecording)
    }

    @Test("a capture that was delivering and went quiet is restarted")
    func flowingCaptureThatGoesQuietRestarts() {
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: true, sinceLastFrame: 1.5,
                restarts: 0) == .restart)
    }

    // MARK: - The bound

    @Test("the last restart inside the limit is still spent")
    func theLimitIsExclusive() {
        #expect(
            watchdog.verdict(
                engineIsRunning: false, hasReceivedAudio: false, sinceLastFrame: 0,
                restarts: watchdog.restartLimit - 1) == .restart)
    }

    @Test("past the restart limit the watchdog gives up instead of rebuilding forever")
    func pastTheLimitItGivesUp() {
        #expect(
            watchdog.verdict(
                engineIsRunning: false, hasReceivedAudio: false, sinceLastFrame: 0,
                restarts: watchdog.restartLimit) == .giveUp)
    }

    @Test("the limit bounds restarts, not the capture: a healthy engine past it keeps recording")
    func theLimitOnlyBoundsRestarts() {
        #expect(
            watchdog.verdict(
                engineIsRunning: true, hasReceivedAudio: true, sinceLastFrame: 0,
                restarts: watchdog.restartLimit) == .keepRecording)
    }
}

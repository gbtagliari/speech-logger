import Foundation

/// What the watchdog says to do about the capture in flight.
public enum CaptureWatchdogVerdict: Equatable, Sendable {
    /// Audio is arriving, or is still within the window it is allowed to take. Nothing
    /// to do.
    case keepRecording
    /// Rebuild the engine, **now**. There is no delay to apply: see `CaptureWatchdog`.
    case restart
    /// The restart budget is spent. Stop rebuilding; whatever the capture has is what
    /// it will have.
    case giveUp
}

/// The recovery policy for a capture whose engine will not stay bound to the device
/// (#63): **rebuild it immediately, with no delay, until audio flows, and stop after a
/// bounded number of tries.**
///
/// The device that produced the ticket is a Bluetooth headset that is default input
/// *and* default output. Bringing the HFP/SCO link up costs several
/// `AVAudioEngineConfigurationChange` events, and the capture dies in one of two shapes
/// depending on where that settling sequence was when the gesture started: the engine is
/// stopped under it (`0 frame(s)`), or the engine keeps running against an input node
/// that resolved before the link existed and delivers nothing for the whole gesture.
/// **One phenomenon, two shapes**, which is why there are two signals here and not two
/// policies.
///
/// Three things about the policy were measured rather than assumed, on that device:
///
/// - **Forcing the rate cannot work.** The headset supports exactly one rate (16 kHz)
///   and already reports it, so writing it back changes nothing and cannot make the
///   device re-publish. The 44.1 kHz the node reports is not an alternative resolution;
///   it is a rate the device does not support at all. This is why the verdict keys on
///   `engineIsRunning` and frame arrival and never on a rate comparison, and why
///   `SampleRateReconciler` was deleted rather than tuned.
/// - **Backoff is worse than no backoff.** Immediate rebuilds settled 3/3 in ~3.5 s at
///   3 restarts; fixed 250 ms settled 0/3 at 10, fixed 500 ms 1/3 at 8.3, exponential
///   0/3 at 10. It is not luck: the SCO link is held up by continuous IO demand, so a
///   pause lets the stack start tearing it down. Hence `restart` carries no delay to
///   apply — there is nowhere to put one.
/// - **Waiting for a warm window does nothing.** Idle gaps from 0.5 s to 15 s before the
///   gesture changed nothing; there is no quiet moment to catch the device in.
///
/// This is mitigation, not a cure: across 10 measured runs it settles most of the time,
/// and one run burned every restart in 20 s and never settled. That is what `giveUp` is
/// for, and why the item it produces fails visibly instead of pretending.
///
/// A value, not a class, and the reason is the last acceptance criterion of #63: the
/// policy has to replay without a Bluetooth headset. Reproducing anything on the real
/// device needs an HFP link coming up under a co-tenant app; the decision itself is
/// arithmetic over four numbers.
public struct CaptureWatchdog: Sendable {
    /// How long the capture may go without a frame **before any frame has ever
    /// arrived**, and still be read as a device that is merely opening.
    ///
    /// Short on purpose: this is the whole of "a capture that never receives audio is
    /// detected in the first moments, not at `stop`". A Bluetooth headset's first frame
    /// lands 1.0–1.6 s after the gesture, but it does not land by *waiting* — the
    /// restarts are what bring it in (#63), so a long window here would buy nothing and
    /// spend the opening words.
    public let openingStall: TimeInterval
    /// How long the capture may go without a frame **once frames have been arriving**.
    ///
    /// Wider than `openingStall`, and it has to be: the tap asks for 4096-frame
    /// buffers, which is a 256 ms period at the 16 kHz an HFP link runs at, so the
    /// opening window is barely one buffer clear of normal delivery. Mid-braindump a
    /// false restart costs real speech, and the engine dying outright is caught by
    /// `engineIsRunning` in the same tick anyway — this window is only the backstop for
    /// an engine that stays "running" and quietly stops delivering.
    public let flowingStall: TimeInterval
    /// How many rebuilds one capture may spend before the watchdog stops trying.
    ///
    /// The bound exists because the rebuild is not free of consequence: each one tears
    /// IO down and brings it up, which is itself a profile transition, which can post
    /// the very configuration change that trips the watchdog again. Unbounded, a device
    /// that will not settle turns into a rebuild loop that runs for as long as the user
    /// holds the key.
    ///
    /// Ten, because ten is what the measured settling costs three times over: the runs
    /// that recovered spent ~3 restarts, and the run that never recovered had spent 10
    /// inside 20 s. A capture that has rebuilt ten times is not one restart away.
    public let restartLimit: Int

    public init(
        openingStall: TimeInterval = 0.4, flowingStall: TimeInterval = 1.0,
        restartLimit: Int = 10
    ) {
        self.openingStall = openingStall
        self.flowingStall = flowingStall
        self.restartLimit = restartLimit
    }

    /// Decide, from one observation of the capture in flight, whether to leave it
    /// alone, rebuild the engine, or stop trying.
    ///
    /// - Parameters:
    ///   - engineIsRunning: whether the capture unit is running (an `AVAudioEngine` until
    ///     #75). Catches the unit stopped out from under the capture (#63, shape 1).
    ///   - hasReceivedAudio: whether any frame has arrived during this capture. It
    ///     selects the stall window, not the verdict.
    ///   - sinceLastFrame: how long since the last frame arrived, or since the engine
    ///     was last started when none has. Catches the engine that stays running and
    ///     delivers nothing (#63, shape 2).
    ///   - restarts: how many rebuilds this capture has already spent.
    ///
    /// The limit bounds *restarts*, not the capture: a capture that is delivering
    /// happily is left alone however many rebuilds it took to get there, and `giveUp` is
    /// only ever reached by a capture that needs another one.
    public func verdict(
        engineIsRunning: Bool,
        hasReceivedAudio: Bool,
        sinceLastFrame: TimeInterval,
        restarts: Int
    ) -> CaptureWatchdogVerdict {
        let stall = hasReceivedAudio ? flowingStall : openingStall
        guard !engineIsRunning || sinceLastFrame > stall else { return .keepRecording }
        return restarts < restartLimit ? .restart : .giveUp
    }
}

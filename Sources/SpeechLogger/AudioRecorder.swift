import AVFoundation
import ObjCExceptionBridge
import QuartzCore
import SpeechLoggerCore
import os

/// Captures the microphone to a native wav in a temp file via `AVAudioEngine`,
/// streamed frame-by-frame so RAM stays O(1) regardless of length. The recorded wav
/// feeds `ffmpeg`, which downmixes to mono/16 kHz (ADR-0002) — the app records
/// native and does not resample itself.
///
/// While recording it accumulates the measurements the guard needs: the per-window RMS
/// sequence and the frame count (which gives both the duration and, at zero, the fact
/// that the capture received nothing). The audio tap runs on a real-time thread, so that
/// state lives behind a lock in `CaptureState`.
///
/// **The engine is disposable, and its own claims about the device are worth nothing.**
/// That is the whole shape of this type, and it took four tickets to arrive at.
///
/// On a Bluetooth headset that is default input *and* default output, bringing the
/// HFP/SCO link up costs several `AVAudioEngineConfigurationChange` events, and the
/// capture dies in one of two shapes depending on where that sequence was when the
/// gesture started: AVFoundation stops the engine under it (`0 frame(s)`), or the engine
/// keeps running against an input node that resolved before the link existed and delivers
/// nothing for the whole gesture (#63). Every call on the way in succeeds. Nothing throws.
///
/// So the recorder watches two things while a capture is in flight — `engine.isRunning`
/// and whether frames are arriving — and answers either with an **immediate** rebuild,
/// bounded by a limit. The policy lives in `CaptureWatchdog`, which is where the measured
/// reasons for immediacy and for the bound are written down, and which replays without a
/// Bluetooth headset.
///
/// Three consequences run through everything below:
///
/// - **Nothing is derived from a format the engine merely resolved.** The wav's format,
///   the energy window's size and the sample rate the duration divides by all come from
///   the *first buffer that actually arrives* (`CaptureState`). A node reporting 44.1 kHz
///   on a device that supports only 16 kHz is not an alternative resolution to reconcile
///   with; it is a rate the device does not have. #59's rate-forcing layer was deleted
///   rather than tuned, because on the ticket's device the write it performs provably
///   cannot do anything.
/// - **`AVAudioEngineConfigurationChange` is not observed at all.** It is not a usable
///   trigger: in one measured run it arrived 129 ms *after* `isRunning` had already
///   exposed the same failure, and it also fires between recordings, where it means
///   nothing.
/// - **Opening the mic is not recording.** `start` returning says a capture is open, not
///   that audio exists; `onAudioFlowing` is the second event, 1.0–1.6 s later on a
///   headset, and it is what the menubar's glyph and clock follow (#63).
///
/// **Nothing in `start` may terminate the process** (#55). The same contention makes
/// `installTapOnBus` reject a format by raising an `NSException`, which Swift cannot
/// catch: no `do`/`catch` sees it, and whatever the user was about to say dies with the
/// process. Two things keep that shut. The format is read off the input node and handed to
/// the install with nothing in between, so the mismatch has no window to open in; and the
/// install goes through `ObjCException`, so what is left is an error. A raise no longer
/// even fails the recording — it fails that *attempt*, and the watchdog tries again on the
/// next tick.
@MainActor final class AudioRecorder: AudioRecording {
    enum RecorderError: Error {
        case microphoneAccessDenied
    }

    /// How often a capture in flight is looked at. Short, because everything it can
    /// detect is measured in hundreds of milliseconds and the opening stall window is
    /// 400 ms: a coarser tick would spend the words it exists to save. The work per tick
    /// is one `isRunning` read, one locked integer read, and arithmetic.
    private static let watchdogInterval: TimeInterval = 0.05
    /// Frames per tap buffer. A hint AVFoundation is free to ignore.
    private static let tapBufferSize: AVAudioFrameCount = 4096

    private let log = Logger(subsystem: "app.speech-logger", category: "recorder")
    /// The restart policy: when to rebuild, and when to stop rebuilding. A hardware-free
    /// seam — this class supplies the two signals and carries out the verdict.
    private let watchdog: CaptureWatchdog
    /// Rebuilt on every restart, and fresh for every capture. Never reused across
    /// gestures: a capture that needed rebuilding says nothing good about the engine it
    /// ended on, and building one costs less than a millisecond.
    private var engine = AVAudioEngine()
    /// Off unless `SPEECH_LOGGER_ENERGY_DUMP` is set; see `EnergyDump`.
    private let energyDump = EnergyDump()
    private var state: CaptureState?
    private var wavURL: URL?
    /// The device the capture was opened against, read once at `start`, so a failure can
    /// name it (#63). Read once and not per tick: it is a CoreAudio round trip, and the
    /// name is for the error message, not for any decision.
    private var deviceName: String?

    // MARK: Per-capture watchdog bookkeeping

    private var timer: Timer?
    /// A capture is in flight. Distinguishes a tick that has work from one that fired
    /// between recordings.
    private var isCapturing = false
    /// Everything the watchdog tracks about the capture in flight, as one value so that
    /// `start` resets it with a single assignment. Five independent flags reset by hand
    /// is a place to forget one, and forgetting here means a previous capture's restart
    /// count deciding this capture's failure.
    private var progress = Progress()

    var onAudioFlowing: (@MainActor () -> Void)?

    /// The watchdog's view of one capture: what it has received, what it has cost, and
    /// when it last made progress.
    private struct Progress {
        /// How many times the engine has been rebuilt under this capture. Carried onto the
        /// capture: non-zero is what tells the guard the device was not delivering, and
        /// what makes the failure name the device instead of shrugging (#63).
        var restarts = 0
        /// Whether any frame has arrived. Selects the stall window, and gates
        /// `onAudioFlowing` to once per capture.
        var hasReceivedAudio = false
        /// Whether the restart budget is already spent, so the giving-up is logged once
        /// and the watchdog keeps observing without rebuilding again.
        var hasGivenUp = false
        /// The frame count at the last tick, so a tick can tell arrival from a plateau.
        var framesAtLastTick: AVAudioFrameCount = 0
        /// When frames last advanced, or when the engine was last started if they never
        /// have. Monotonic (`CACurrentMediaTime`), never wall-clock.
        var lastProgressAt: CFTimeInterval = 0
    }

    /// The policy is injected so it can be tuned (or, in a probe, replaced) without
    /// touching the mechanics. Production takes the measured defaults.
    init(watchdog: CaptureWatchdog = CaptureWatchdog()) {
        self.watchdog = watchdog
    }

    func start() throws(RecorderError) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Prompt for next time; this attempt cannot proceed synchronously.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw RecorderError.microphoneAccessDenied
        case .denied, .restricted:
            throw RecorderError.microphoneAccessDenied
        @unknown default:
            throw RecorderError.microphoneAccessDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-\(UUID().uuidString).wav")
        // The wav is *named* here and opened by the first buffer that arrives, against
        // that buffer's own format. Opening it now would mean guessing the format from a
        // node that has not resolved the device yet, and every buffer after a rebuild
        // that resolved differently would fail to write into it.
        state = CaptureState(wav: url, windowDuration: RecordingCapture.windowDuration)
        wavURL = url
        deviceName = Microphone.defaultInputDeviceName

        progress = Progress(lastProgressAt: CACurrentMediaTime())
        isCapturing = true

        // Best effort, and deliberately not fatal. A first open that fails is the
        // ticket's own case — the SCO link is not up yet — and the recording it would
        // have refused is exactly the one worth saving. The watchdog sees a stopped
        // engine on its next tick and rebuilds; if it never comes up, the capture fails
        // visibly at `stop` naming the device, which beats a log line nobody reads.
        openEngine()
        startWatchdog()
    }

    func stop() -> RecordingCapture {
        isCapturing = false
        stopWatchdog()
        teardownEngine()

        let snapshot = state?.snapshot ?? .empty
        if let openFailure = snapshot.openFailure {
            // The one failure the tap could not report itself: it runs on a real-time
            // thread, so it kept the reason and this is where it gets said.
            log.error("the capture wav could not be opened: \(openFailure, privacy: .public)")
        }
        if snapshot.droppedWrites > 0 {
            // The energy measurements still hold, but the retained wav is missing frames
            // — record it rather than swallow it.
            log.warning("audio capture dropped \(snapshot.droppedWrites) buffer write(s)")
        }
        // Measured off the frames that reached the wav, divided by the rate the audio
        // actually arrived at. Both halves matter: a rate the engine merely claimed is a
        // fiction on the device this ticket is about, and frames that were delivered but
        // never written are not in the audio the pipeline is about to transcribe. With no
        // audio there is no rate, and the duration is honestly zero.
        let duration =
            snapshot.sampleRate > 0 ? Double(snapshot.writtenFrames) / snapshot.sampleRate : 0
        let url =
            wavURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-logger-empty.wav")
        let restarts = progress.restarts
        let deviceName = self.deviceName

        state = nil  // flushes and closes the AVAudioFile
        wavURL = nil
        self.deviceName = nil

        energyDump.write(snapshot.windowEnergies)
        return RecordingCapture(
            wav: url, duration: duration, frames: Int(snapshot.frames),
            windowEnergies: snapshot.windowEnergies, engineRestarts: restarts,
            deviceName: deviceName)
    }

    // MARK: - The engine, built and rebuilt (#63)

    /// Build an engine, tap it, and start it. Every failure on the way is an attempt that
    /// did not work, never a recording that is over: the engine is left not-running and
    /// the next tick rebuilds.
    ///
    /// The format is read off the input node and handed to `installTap` with nothing in
    /// between (#55). It is not read for anything else — not for the wav, not for the
    /// window size, not for the duration — because it is what the engine *resolved*, and
    /// on the device this ticket is about that number is a fiction.
    private func openEngine() {
        guard let state else { return }
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        do {
            // The tap fires on a realtime audio thread. Mark the block `@Sendable` so it
            // is non-isolated: without this the compiler infers `@MainActor` isolation
            // from the enclosing actor and the Swift 6 runtime traps (SIGTRAP) when
            // AVFoundation invokes it off the main thread. `state` is `Sendable`.
            try ObjCException.catching {
                input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
                    @Sendable buffer, _ in
                    state.append(buffer)
                }
            }
        } catch {
            // A raise leaves no tap behind, so there is nothing to remove. The engine
            // never starts, which is precisely the condition the watchdog acts on.
            log.warning("installing the tap raised: \(String(describing: error), privacy: .public)")
            return
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.warning("starting the engine failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drop the tap and the engine. Safe on an engine that never started and on one that
    /// was never tapped.
    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)  // no more writes after this
        engine.stop()
    }

    // MARK: - The watchdog

    private func startWatchdog() {
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` rather than the default mode: the menubar popover and any menu put the
        // run loop in a tracking mode, and a watchdog that stops watching while the panel
        // happens to be open would leave exactly the capture it exists for unattended.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopWatchdog() {
        timer?.invalidate()
        timer = nil
    }

    /// One observation of the capture in flight: note any frames that arrived, then do
    /// what the policy says.
    ///
    /// Frame arrival is read as a *count that advanced*, not as a callback from the tap.
    /// The tap runs on a real-time thread and must not hop actors per buffer; a locked
    /// integer read every 50 ms costs nothing and cannot glitch the audio.
    private func tick() {
        guard isCapturing, let state else { return }
        let now = CACurrentMediaTime()

        let frames = state.frameCount
        if frames > progress.framesAtLastTick {
            progress.framesAtLastTick = frames
            progress.lastProgressAt = now
            if !progress.hasReceivedAudio {
                progress.hasReceivedAudio = true
                log.notice(
                    """
                    first audio frame after \(self.progress.restarts, privacy: .public) \
                    engine restart(s)
                    """)
                // The only moment anything is allowed to say "recording" (#63).
                onAudioFlowing?()
            }
        }

        switch watchdog.verdict(
            engineIsRunning: engine.isRunning, hasReceivedAudio: progress.hasReceivedAudio,
            sinceLastFrame: now - progress.lastProgressAt, restarts: progress.restarts) {
        case .keepRecording:
            break
        case .restart:
            restart()
        case .giveUp:
            guard !progress.hasGivenUp else { return }
            progress.hasGivenUp = true
            log.error(
                """
                \(self.deviceLabel, privacy: .public) would not deliver audio after \
                \(self.progress.restarts, privacy: .public) engine restart(s); the \
                capture will fail visibly rather than rebuild forever
                """)
        }
    }

    /// The device as a message names it, falling back to the same wording the failure
    /// detail uses so the log line and the item's error agree.
    private var deviceLabel: String {
        deviceName ?? RecordingCapture.unnamedDevice
    }

    /// Rebuild the engine, **now**. There is no delay to apply and adding one makes it
    /// worse: the SCO link is held up by continuous IO demand, so a pause between the
    /// teardown and the next start lets the stack begin tearing it down. Measured, in
    /// `CaptureWatchdog`.
    ///
    /// The accumulated audio is untouched: `CaptureState` outlives every engine, so a
    /// rebuild costs the frames that were never going to arrive and nothing else.
    private func restart() {
        progress.restarts += 1
        log.warning(
            """
            rebuilding the audio engine (restart \(self.progress.restarts, privacy: .public)): \
            running \(self.engine.isRunning, privacy: .public), audio \
            \(self.progress.hasReceivedAudio, privacy: .public)
            """)
        teardownEngine()
        openEngine()
        // The fresh engine gets its own stall window, counted from now.
        progress.lastProgressAt = CACurrentMediaTime()
    }
}

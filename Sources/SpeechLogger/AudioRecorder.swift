import AVFoundation
import QuartzCore
import SpeechLoggerCore
import os

/// Captures the microphone to a 16 kHz mono wav in a temp file through a Core Audio HAL unit
/// (`CaptureUnit`, #75), streamed frame-by-frame so RAM stays O(1) regardless of length.
/// Every buffer is converted to that one format as it arrives (`CaptureState`, #69), because
/// a device can change its rate mid-capture; the wav then feeds `ffmpeg` for the mp3
/// (ADR-0002).
///
/// While recording it accumulates the measurements the guard needs: the per-window RMS
/// sequence and the frame count (which gives both the duration and, at zero, the fact
/// that the capture received nothing). The input callback runs on a real-time thread, so
/// that state lives behind a lock in `CaptureState`.
///
/// **Which device is a decision made here, fresh at every `start`** (`CaptureDevicePolicy`,
/// ADR-0011). A Bluetooth default input is skipped for the built-in mic when one exists, so
/// the headset never enters HFP. The unit is bound to that device before it is initialized,
/// which is what `AVAudioEngine` could not do (ADR-0010). Every rebuild within a capture
/// binds the same device.
///
/// **The unit is disposable, and its own claims about the device are worth nothing.**
/// The recorder watches two things while a capture is in flight — whether the unit is
/// running and whether frames are arriving — and answers either with an **immediate**
/// rebuild, bounded by a limit. The policy lives in `CaptureWatchdog`, which is where the
/// measured reasons for immediacy and for the bound are written down (#63), and which
/// replays without a Bluetooth headset. A device whose rate changes under a running unit
/// shows up as render errors and no frames; the flowing stall catches it and the rebuild
/// reads the new format.
///
/// Three consequences run through everything below:
///
/// - **Nothing is derived from a format the unit read, or from any one buffer's.** The wav,
///   the energy windows and the duration are all in the fixed capture format, and each
///   buffer is converted from whatever format it arrived in (`CaptureState`).
/// - **Opening the mic is not recording.** `start` returning says a capture is open, not
///   that audio exists; `onAudioFlowing` is the second event, and it is what the menubar's
///   glyph and clock follow (#63).
/// - **Disposable means disposed, at `stop` as much as at a restart.** A unit holds the
///   device until it is disposed. Between captures there is no unit, so a headset is never
///   held in HFP between recordings.
///
/// **Nothing in `start` may terminate the process** (#55). An open that fails is an attempt
/// that did not work, never a crash and never a refused recording: the watchdog sees no
/// running unit on its next tick and rebuilds.
@MainActor final class AudioRecorder: AudioRecording {
    enum RecorderError: Error {
        case microphoneAccessDenied
    }

    /// How often a capture in flight is looked at. Short, because everything it can
    /// detect is measured in hundreds of milliseconds and the opening stall window is
    /// 400 ms: a coarser tick would spend the words it exists to save. The work per tick
    /// is one `isRunning` read, one locked integer read, and arithmetic.
    private static let watchdogInterval: TimeInterval = 0.05

    private let log = Logger(subsystem: "app.speech-logger", category: "recorder")
    /// The restart policy: when to rebuild, and when to stop rebuilding. A hardware-free
    /// seam — this class supplies the two signals and carries out the verdict.
    private let watchdog: CaptureWatchdog
    /// Rebuilt on every restart, and fresh for every capture. Nil between captures, which is
    /// the device released.
    private var unit: CaptureUnit?
    /// Off unless `SPEECH_LOGGER_ENERGY_DUMP` is set; see `EnergyDump`.
    private let energyDump = EnergyDump()
    private var state: CaptureState?
    private var wavURL: URL?
    /// The device this capture records from, chosen once at `start` and bound by every
    /// rebuild, so a failure names the device actually recorded from (#63, #75).
    private var device: InputDevice?

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
        /// How many times the unit has been rebuilt under this capture. Carried onto the
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
        /// When frames last advanced, or when the last unit open returned if they never
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

        let resolution = InputDevices.resolve()
        device = resolution.choice?.device
        log.notice(
            """
            capture device: \(resolution.choice?.device.logLabel ?? "none", privacy: .public); \
            default input: \(resolution.defaultInput?.logLabel ?? "none", privacy: .public); \
            reason: \(resolution.choice?.reason.rawValue ?? "no default input", privacy: .public)
            """)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-\(UUID().uuidString).wav")
        state = CaptureState(wav: url)
        wavURL = url

        progress = Progress()
        isCapturing = true

        // Best effort, and deliberately not fatal: the recording a failed first open would
        // have refused is exactly the one worth saving. The watchdog sees no running unit on
        // its next tick and rebuilds; if it never comes up, the capture fails visibly at
        // `stop` naming the device, which beats a log line nobody reads.
        openUnit()
        // Counted from the open *returning*, as `restart` does (#69): the open can block, and
        // that wait is not the device stalling.
        progress.lastProgressAt = CACurrentMediaTime()
        startWatchdog()
    }

    func stop() -> RecordingCapture {
        isCapturing = false
        stopWatchdog()
        disposeUnit()

        let snapshot = state?.snapshot ?? .empty
        if let openFailure = snapshot.openFailure {
            // The one failure the input callback could not report itself: it runs on a
            // real-time thread, so it kept the reason and this is where it gets said.
            log.error("the capture wav could not be opened: \(openFailure, privacy: .public)")
        }
        if let conversionFailure = snapshot.conversionFailure {
            log.error("a capture buffer could not be converted: \(conversionFailure, privacy: .public)")
        }
        if snapshot.droppedBuffers > 0 {
            // The energy measurements still hold, but the retained wav is missing frames
            // — record it rather than swallow it.
            log.warning("audio capture dropped \(snapshot.droppedBuffers) buffer(s)")
        }
        let url =
            wavURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-logger-empty.wav")
        let restarts = progress.restarts
        let deviceName = device?.name

        state = nil  // flushes and closes the AVAudioFile
        wavURL = nil
        device = nil

        energyDump.write(snapshot.windowEnergies)
        return RecordingCapture(
            wav: url, duration: snapshot.duration, frames: Int(snapshot.deliveredFrames),
            windowEnergies: snapshot.windowEnergies, engineRestarts: restarts,
            deviceName: deviceName)
    }

    // MARK: - The unit, built and rebuilt (#63)

    /// Open a unit on the chosen device. A failure is an attempt that did not work, never a
    /// recording that is over: there is no unit, which reads as not running, and the next
    /// tick rebuilds.
    private func openUnit() {
        guard let state else { return }
        guard let device else {
            log.warning("no input device to capture from")
            return
        }
        do {
            let unit = try CaptureUnit.open(device: AudioDeviceID(device.id), into: state)
            self.unit = unit
            log.notice("capture unit open: \(unit.format, privacy: .public)")
        } catch {
            log.warning("opening the capture unit failed: \(error.description, privacy: .public)")
        }
    }

    /// Stop the unit and **release the device with it**.
    ///
    /// This is also the teardown half of a restart, where the release costs nothing: the
    /// rebuild is the next statement.
    private func disposeUnit() {
        guard let unit else { return }
        unit.dispose()
        if unit.renderErrors > 0 {
            log.warning("the capture unit had \(unit.renderErrors, privacy: .public) render error(s)")
        }
        self.unit = nil
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
    /// Frame arrival is read as a *count that advanced*, not pushed from the input callback,
    /// which runs on a real-time thread and must not hop actors per buffer; a locked
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

        // No unit reads as not running, which is the condition the watchdog rebuilds on.
        // Inside a capture that state is momentary — the teardown and the rebuild are
        // consecutive statements on this actor, so no tick can land between them.
        switch watchdog.verdict(
            engineIsRunning: unit?.isRunning ?? false, hasReceivedAudio: progress.hasReceivedAudio,
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
        device?.name ?? RecordingCapture.unnamedDevice
    }

    /// Rebuild the unit on the same device, **now**. There is no delay to apply and adding
    /// one makes it worse on a Bluetooth device: the SCO link is held up by continuous IO
    /// demand. Measured, in `CaptureWatchdog`.
    ///
    /// The accumulated audio is untouched: `CaptureState` outlives every unit, so a rebuild
    /// costs the frames that were never going to arrive and nothing else.
    private func restart() {
        progress.restarts += 1
        log.warning(
            """
            rebuilding the capture unit (restart \(self.progress.restarts, privacy: .public)): \
            running \(self.unit?.isRunning ?? false, privacy: .public), render errors \
            \(self.unit?.renderErrors ?? 0, privacy: .public), audio \
            \(self.progress.hasReceivedAudio, privacy: .public)
            """)
        disposeUnit()
        openUnit()
        // The fresh unit gets its own stall window, counted from the open returning.
        progress.lastProgressAt = CACurrentMediaTime()
    }
}

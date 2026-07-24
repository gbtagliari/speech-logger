import AVFoundation
import AudioToolbox
import CoreAudio
import ObjCExceptionBridge
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
/// The engine is **not** a constant, and the input node's format is **not** taken on
/// trust (#54). One `AVAudioEngine` lives for the whole process, so it outlives every
/// device change the user makes, and under microphone contention it resolves the input
/// node to a 44.1 kHz fallback while the device runs at another rate — then delivers
/// zero frames, with nothing throwing anywhere. The format is confronted with the device
/// before a recording opens against it, and a configuration change drops the binding so
/// the next recording rebuilds.
///
/// Rebuilding alone does not clear that fallback, though — the AUHAL keeps the stale rate
/// across a fresh engine and even across a process restart (#59). So a disagreement is
/// answered by *forcing* the device to re-publish its format
/// (`Microphone.forceDefaultInputSampleRate`) and re-pointing the input AUHAL at it
/// (`reresolveInputAgainstDevice`), not by rebuilding and hoping. The decision behind
/// that force lives in `SampleRateReconciler`, a hardware-free seam.
///
/// **Nothing in `start` may terminate the process** (#55). The same contention makes
/// `installTapOnBus` reject a format by raising an `NSException`, which Swift cannot
/// catch: no `do`/`catch` sees it, `onRecorderStartFailed` never fires, and whatever the
/// user was about to say dies with the process. Two things keep that shut. The format is
/// read off a verified node and handed to the install with nothing in between, so the
/// mismatch has no window to open in; and the install itself goes through
/// `ObjCException`, so what is left surfaces as a `RecorderError` and degrades like every
/// other prerequisite failure in this app (ADR-0004).
@MainActor final class AudioRecorder: AudioRecording {
    enum RecorderError: Error {
        case microphoneAccessDenied
        case engineFailed(String)
    }

    /// How far the engine's sample rate may sit from the device's and still be believed.
    /// Both are doubles the drivers computed, so this is a float comparison, not a
    /// tolerance for genuinely different rates: the failure it catches is 44100 against
    /// 16000, not 48000.0 against 47999.9.
    private static let sampleRateTolerance: Double = 1

    private let log = Logger(subsystem: "app.speech-logger", category: "recorder")
    /// Reconciles the engine's cached input rate with the device's actual rate, forcing
    /// the device to re-publish when they disagree (#59). The device it forces is a seam,
    /// so the flow is unit-tested without hardware; this recorder owns only the CoreAudio
    /// conformer and the engine rebuild the decision triggers.
    private let reconciler: SampleRateReconciler
    private var engine = AVAudioEngine()
    /// The `AVAudioEngineConfigurationChange` subscription, re-registered whenever the
    /// engine is rebuilt (the notification is posted by a specific engine).
    private var configurationObserver: (any NSObjectProtocol)?
    /// Set when the audio graph changed under us: the engine's binding to the device is
    /// stale, and the next recording rebuilds rather than reuses it.
    private var isEngineStale = false
    /// Off unless `SPEECH_LOGGER_ENERGY_DUMP` is set; see `EnergyDump`.
    private let energyDump = EnergyDump()
    private var state: CaptureState?
    private var wavURL: URL?
    private var sampleRate: Double = 0
    /// Whether the engine could not bind the device for the capture in flight (#60). Two
    /// shapes feed it, both of which criterion 1 of #60 names: `verifiedInputNode` sets it
    /// when the input node's rate never reconciled with the device at open (the #59 rate
    /// mismatch), and `markEngineStale` sets it when the audio graph changes *under* an
    /// active capture (a device dropping mid-gesture — the ticket's own repro). Carried
    /// onto the capture as its `deviceBindingFailed` so the guard fails a *short* dead
    /// capture the warm-up allowance would otherwise discard as an accidental tap. Reset
    /// per recording — it describes this capture's binding, nothing older.
    private var deviceBindingFailed = false
    /// Whether a capture is in flight, so a mid-recording configuration change can be told
    /// from one that arrives between recordings. Set once the engine is running and
    /// cleared before it is torn down, so the deliberate stop below is never misread as a
    /// device dropping under the capture (#60).
    private var isCapturing = false

    /// The device seam is injected so the reconciliation flow is testable without
    /// hardware; production takes the CoreAudio conformer. The tolerance is shared with
    /// the post-rebuild check below so the two agree on what "the same rate" means.
    init(device: any InputDeviceRate = CoreAudioInputDevice()) {
        reconciler = SampleRateReconciler(device: device, tolerance: Self.sampleRateTolerance)
        observeConfigurationChanges()
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

        let input = verifiedInputNode()
        // The window is a fixed span of time, so its size in frames follows the device's
        // native rate. Read on its own, and allowed to be a hair stale: a window sized
        // off a rate that has since moved is a rounding error, while a *format* that has
        // moved is the raise this whole sequence exists to avoid. `max(1, …)` only guards
        // against a nonsense rate.
        let windowRate = input.outputFormat(forBus: 0).sampleRate
        let state = CaptureState(
            windowFrames: max(1, Int((windowRate * RecordingCapture.windowDuration).rounded())))

        // Read and installed in one step (#55). Nothing stands between these two
        // statements — not the wav, which is opened below, and not an allocation — so the
        // node's format has no window to move in, and the install has no stale format to
        // reject by raising.
        let format = input.outputFormat(forBus: 0)  // native (e.g. 48 kHz stereo)
        do {
            // The tap fires on a realtime audio thread. Mark the block `@Sendable` so it
            // is non-isolated: without this the compiler infers `@MainActor` isolation
            // from the enclosing actor and the Swift 6 runtime traps (SIGTRAP) when
            // AVFoundation invokes it off the main thread. `state` is `Sendable`.
            try ObjCException.catching {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
                    state.append(buffer)
                }
            }
        } catch {
            // A raise leaves no tap behind, so there is nothing to remove here. What it
            // does leave is an engine whose binding to the hardware disagreed with itself
            // one statement apart: not to be trusted for the next gesture either, so the
            // next recording rebuilds rather than raising again.
            isEngineStale = true
            throw RecorderError.engineFailed("installing the tap: \(error)")
        }

        // Only now the wav, opened against the same format the tap was installed with.
        // Nothing is missed by opening it after: a tap delivers only while the engine
        // runs, and the engine starts below.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-\(UUID().uuidString).wav")
        do {
            state.attach(try AVAudioFile(forWriting: url, settings: format.settings))
        } catch {
            throw abandonStart(input, wav: url, "opening wav for writing: \(error)")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw abandonStart(input, wav: url, "starting engine: \(error)")
        }

        self.state = state
        wavURL = url
        // The engine is running: a configuration change from here on is a device moving
        // under a live capture, not one arriving between recordings (#60).
        isCapturing = true
        // Last, and only on the way out: a failed start leaves no rate behind for a
        // `stop` that never had a recording to stop.
        sampleRate = format.sampleRate
    }

    /// Tear down a start that got far enough to leave something behind, and name the
    /// failure it is being torn down for. The tap and the temp wav are the two things
    /// `stop` would have owned; nothing else is set until `start` returns, so there is
    /// nothing else to undo.
    private func abandonStart(
        _ input: AVAudioInputNode, wav url: URL, _ detail: String
    ) -> RecorderError {
        input.removeTap(onBus: 0)
        // A wav opened for a recording that never happens is temp litter: the capture
        // that does happen is the only one the pipeline deletes for us.
        try? FileManager.default.removeItem(at: url)
        return .engineFailed(detail)
    }

    func stop() -> RecordingCapture {
        // Before the teardown: `engine.stop()` can itself post a configuration change,
        // and this is a deliberate stop, not a device dropping under the capture (#60).
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)  // no more writes after this
        engine.stop()

        let snapshot = state?.snapshot ?? (windowEnergies: [], frames: 0, droppedWrites: 0)
        if snapshot.droppedWrites > 0 {
            // The energy/duration measurements still hold, but the retained wav is
            // missing frames — record it rather than swallow it.
            log.warning("audio capture dropped \(snapshot.droppedWrites) buffer write(s)")
        }
        let duration = sampleRate > 0 ? Double(snapshot.frames) / sampleRate : 0
        let url = wavURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-empty.wav")
        let bindingFailed = deviceBindingFailed

        state = nil  // flushes and closes the AVAudioFile
        wavURL = nil
        sampleRate = 0
        deviceBindingFailed = false

        energyDump.write(snapshot.windowEnergies)
        return RecordingCapture(
            wav: url, duration: duration, frames: Int(snapshot.frames),
            windowEnergies: snapshot.windowEnergies, deviceBindingFailed: bindingFailed)
    }

    // MARK: - The engine's binding to the device (#54)

    /// An input node worth opening a recording against: confronted with the device
    /// first, off an engine that is not stale.
    ///
    /// The single owner of "is this engine's binding to the hardware still good", so
    /// `start` asks one question instead of sequencing two.
    ///
    /// The **node**, not its format, and deliberately so (#55): a format is only good for
    /// the instant it was read, and `installTapOnBus` answers a stale one by raising. The
    /// caller reads the format off the node it gets back, immediately before installing.
    ///
    /// `outputFormat(forBus: 0)` is what `AVAudioEngine` *resolved*, not what the device
    /// is running. Under contention — another process holding the input, or having just
    /// released it, which is what leaving a Meet does — the two disagree, the engine pins
    /// its input node to a 44.1 kHz fallback, and then it delivers zero frames while
    /// every call on the way in succeeds.
    ///
    /// #54 rebuilt the engine and hoped a fresh one would re-resolve. It does not: the
    /// AUHAL keeps the stale fallback across the rebuild, and even a full process restart
    /// stays stuck until the device re-publishes its format (#59). So the disagreement is
    /// not answered by rebuilding but by *forcing* the device's nominal rate — which
    /// makes it re-publish — and only then rebuilding, so the fresh engine resolves
    /// against a live format. The rebuild additionally re-points the input AUHAL at the
    /// device (`rebuildEngine`), the other half of clearing the fallback.
    ///
    /// If they still disagree the recording proceeds anyway. That is the same asymmetry
    /// the rest of the app is built on: refusing here costs a thought on a microphone
    /// that might have worked, while proceeding costs, at worst, a `failed` item the
    /// user can see — which is precisely what the guard's dead-capture verdict is for.
    private func verifiedInputNode() -> AVAudioInputNode {
        // Fresh per recording: this capture's binding is judged on this recording's
        // reconciliation, not a prior one's (#60).
        deviceBindingFailed = false
        // A configuration change already invalidated the binding: rebuild before asking
        // the node anything, rather than confronting a format we know is stale.
        if isEngineStale { rebuildEngine() }
        let engineRate = engine.inputNode.outputFormat(forBus: 0).sampleRate

        // The rate to reconcile against, once the reconciler has (or has not) forced the
        // device to re-publish. Either disagreement leads to the same recovery — rebuild,
        // which re-points the input AUHAL at the live device — because the AUHAL re-point
        // does not hinge on the device write having taken. `.notNeeded` is the only exit
        // that skips it: the engine already agrees, or there is no device rate to confront
        // it with, and an unknown is believed (the rule the microphone check follows too).
        let deviceRate: Double
        switch reconciler.reconcile(engineRate: engineRate) {
        case .notNeeded:
            return engine.inputNode
        case .forced(let rate):
            log.warning(
                """
                input node at \(engineRate, privacy: .public) Hz against a device at \
                \(rate, privacy: .public) Hz; forced the device rate and rebuilding
                """)
            deviceRate = rate
        case .failed(let rate):
            log.warning(
                """
                input node at \(engineRate, privacy: .public) Hz against a device at \
                \(rate, privacy: .public) Hz that would not take a forced rate; \
                re-pointing the AUHAL and rebuilding
                """)
            deviceRate = rate
        }

        rebuildEngine()
        let rebuilt = engine.inputNode.outputFormat(forBus: 0).sampleRate
        if abs(rebuilt - deviceRate) > Self.sampleRateTolerance {
            // The device never re-published a rate the engine picked up. Record anyway:
            // the guard's dead-capture verdict fails the item where the user can see it,
            // which is the last resort #54 exists to be. Remember it: a capture that then
            // reads nothing but zeros is dead at any length, and this is the tell that
            // separates a short dead capture from an accidental tap (#60).
            deviceBindingFailed = true
            log.error(
                """
                input node still at \(rebuilt, privacy: .public) Hz after reconciling \
                against \(deviceRate, privacy: .public) Hz; recording anyway, and a \
                capture that receives nothing will fail the item visibly
                """)
        }
        return engine.inputNode
    }

    /// Drop the engine and build a fresh one, re-subscribing to its configuration
    /// changes and re-pointing its input at the live device. Only ever called between
    /// recordings — the coordinator makes recording exclusive — so there is no live tap
    /// to tear down.
    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        isEngineStale = false
        observeConfigurationChanges()
        reresolveInputAgainstDevice()
    }

    /// Re-point the input AUHAL at the current default input device, forcing it to
    /// re-read that device's stream format instead of carrying the fallback a fresh
    /// engine still resolves to on its own (#59). Setting the current device — even to
    /// the same id — is what makes the AUHAL reconcile; a bare `AVAudioEngine()` does
    /// not. The other half is `Microphone.forceDefaultInputSampleRate`, which makes the
    /// device re-publish in the first place.
    ///
    /// Best-effort and never fatal: a device that cannot be re-pointed leaves the engine
    /// exactly where the bare rebuild left it, and the post-rebuild check in
    /// `verifiedInputNode` still catches a rate that never reconciled.
    private func reresolveInputAgainstDevice() {
        guard let deviceID = Microphone.defaultInputDeviceID,
            let audioUnit = engine.inputNode.audioUnit
        else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            log.notice(
                "could not re-point the input AUHAL at the default device (status \(status, privacy: .public))")
        }
    }

    /// Watch for the audio graph changing under the engine: a device plugged, unplugged,
    /// or switched by the user, or the sample rate moving. Nothing in the app observed
    /// this before, and one engine lives for the whole process, so a stale binding could
    /// outlive every device change the user made.
    ///
    /// The engine is not rebuilt here. A change can arrive mid-recording, where a rebuild
    /// would throw away the capture in flight; marking it stale defers the rebuild to the
    /// next `start`, which is the only moment a fresh engine is worth anything.
    ///
    /// A change that arrives while a capture *is* in flight is also the device dropping
    /// under that capture — the ticket's own repro, a headset disconnecting mid-gesture
    /// (#60). It is recorded as a binding failure on this capture, so a short all-zero
    /// recording that follows fails visibly rather than discarding as an accidental tap.
    ///
    /// The previous subscription is removed here and nowhere else: there is no `deinit`,
    /// because a `@MainActor` class cannot touch a non-`Sendable` token from a nonisolated
    /// one. Bounded on purpose — one recorder lives for the whole process, exactly one
    /// subscription is registered at a time, and the block holds `self` weakly, so an
    /// outliving observer could not reach a freed recorder anyway.
    private func observeConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Posted on whatever thread the change arrived on; hop to the actor that
            // owns the flag.
            Task { @MainActor in self?.markEngineStale() }
        }
    }

    private func markEngineStale() {
        isEngineStale = true
        if isCapturing {
            // The graph changed under a live capture: the device dropped mid-gesture, so
            // what the tap reads from here on is not to be trusted (#60). Fail this
            // capture's binding — a short all-zero recording is then dead, not an
            // accidental tap. A change between recordings leaves this alone; `start`
            // resolves a fresh binding for the next capture.
            deviceBindingFailed = true
        }
        log.notice("audio configuration changed; the engine will be rebuilt on the next recording")
    }
}

/// Accumulation for the audio tap: the file write plus the per-window RMS sequence
/// and the frame count. The tap fires on a real-time thread; `snapshot` is read on
/// the main actor after the tap is removed.
///
/// It is built without its file and given one by `attach` before the engine starts,
/// because the tap install must sit immediately after the format read (#55).
///
/// Windows are fixed and span buffer boundaries: a window's partial sum carries over
/// to the next buffer and closes when `windowFrames` frames have gone into it. The
/// tap's `bufferSize` is a hint AVFoundation is free to ignore, so measuring per
/// buffer would leave the window size at the mercy of the device.
///
/// **Why the energy state is not under the lock.** The tap is its *only* writer, and
/// the per-sample fold plus the array growth are exactly the work that must not run
/// while holding a lock on a real-time thread. Visibility instead comes from the lock
/// the tap takes immediately afterwards for the shared counters: those writes are
/// released by `unlock`, and `snapshot`'s `lock` acquires that same release, so
/// everything the tap wrote before it is visible to the reader. `snapshot` runs only
/// after `removeTap`, so there is no concurrent writer to race with either.
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    /// Frames per energy window, at the device's native sample rate.
    private let windowFrames: Int

    // Tap-only state. See the note above on why it carries no lock.
    private var windowEnergies: [Float] = []
    /// The window currently filling: sum of squared samples, how many samples went
    /// into that sum, and how many frames it has taken.
    private var windowSquares: Float = 0
    private var windowSquareCount = 0
    private var windowFilled = 0

    // Shared state, guarded by `lock`. For `file` the lock guards the *reference* —
    // handed over by `attach`, read by the tap — and not the writing, which happens
    // outside it; there is only ever one writer, and it is the tap.
    /// The wav being written. Absent until `attach`, which runs before the engine does.
    private var file: AVAudioFile?
    private var frames: AVAudioFrameCount = 0
    private var droppedWrites = 0

    init(windowFrames: Int) {
        self.windowFrames = windowFrames
        // A minute of headroom, so the common recording never reallocates on the
        // audio thread. Past it, doubling makes a growth a rare event, not a
        // per-window one.
        windowEnergies.reserveCapacity(Int(60 / RecordingCapture.windowDuration))
    }

    /// Hand the state the wav to write into. Separate from `init` because the tap is
    /// installed before the file is opened (#55): the format must reach `installTap`
    /// with nothing in between. Called on the main actor between the install and
    /// `engine.start()`, so the file is in place before the tap can fire even once.
    func attach(_ file: AVAudioFile) {
        lock.lock()
        self.file = file
        lock.unlock()
    }

    /// One lock acquisition per buffer on the audio thread, the same as before the file
    /// became something to read: the file reference and the frame count are taken
    /// together, and the write itself — the slow part — stays outside. A second
    /// acquisition happens only when a write is lost, which is not the hot path.
    func append(_ buffer: AVAudioPCMBuffer) {
        accumulate(buffer)
        lock.lock()
        let file = self.file
        frames += buffer.frameLength
        lock.unlock()

        // Cannot throw off the real-time tap; a lost write is counted so it is reported
        // rather than silently swallowed. A buffer with no file behind it is the same
        // loss and counts the same way — it would mean a tap fired before `attach`,
        // which the start sequence does not allow.
        let didWrite = if let file { (try? file.write(from: buffer)) != nil } else { false }
        guard !didWrite else { return }
        lock.lock()
        droppedWrites += 1
        lock.unlock()
    }

    /// The trailing partial window is included: dropping it would throw away up to
    /// 20 ms, which is a fifth of a 100 ms utterance's evidence.
    var snapshot: (windowEnergies: [Float], frames: AVAudioFrameCount, droppedWrites: Int) {
        lock.lock()
        defer { lock.unlock() }
        let trailing = windowSquareCount > 0 ? [(windowSquares / Float(windowSquareCount)).squareRoot()] : []
        return (windowEnergies + trailing, frames, droppedWrites)
    }

    /// Fold the buffer into the window sequence, closing a window every
    /// `windowFrames` frames.
    ///
    /// A window's energy is the RMS across all channels of its frames, so a stereo
    /// device with one dead channel halves the measured energy rather than reporting
    /// the louder channel. The floor is set well below speech precisely so that kind
    /// of margin is absorbed.
    ///
    /// `AVAudioEngine` input is float32, so `floatChannelData` is present. A non-float
    /// format (not seen in practice) contributes no windows at all, which the guard
    /// reads as *measured nothing* rather than as silence — the recording is kept.
    private func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                windowSquares += sample * sample
            }
            windowSquareCount += channelCount
            windowFilled += 1
            if windowFilled >= windowFrames {
                windowEnergies.append((windowSquares / Float(windowSquareCount)).squareRoot())
                windowSquares = 0
                windowSquareCount = 0
                windowFilled = 0
            }
        }
    }
}

import AVFoundation
import SpeechLoggerCore
import os

/// Captures the microphone to a native wav in a temp file via `AVAudioEngine`,
/// streamed frame-by-frame so RAM stays O(1) regardless of length. The recorded wav
/// feeds `ffmpeg`, which downmixes to mono/16 kHz (ADR-0002) — the app records
/// native and does not resample itself.
///
/// While recording it accumulates the two measurements the dual guard needs: the
/// per-window RMS sequence and the frame count (for duration). The audio tap runs on
/// a real-time thread, so that state lives behind a lock in `CaptureState`.
@MainActor final class AudioRecorder: AudioRecording {
    enum RecorderError: Error {
        case microphoneAccessDenied
        case engineFailed(String)
    }

    private let log = Logger(subsystem: "app.speech-logger", category: "recorder")
    private let engine = AVAudioEngine()
    /// Off unless `SPEECH_LOGGER_ENERGY_DUMP` is set; see `EnergyDump`.
    private let energyDump = EnergyDump()
    private var state: CaptureState?
    private var wavURL: URL?
    private var sampleRate: Double = 0

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

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)  // native (e.g. 48 kHz stereo)
        sampleRate = format.sampleRate

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-logger-\(UUID().uuidString).wav")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            throw RecorderError.engineFailed("opening wav for writing: \(error)")
        }
        // The window is a fixed span of time, so its size in frames follows the
        // device's native rate. `max(1, …)` only guards against a nonsense rate.
        let windowFrames = max(1, Int((format.sampleRate * RecordingCapture.windowDuration).rounded()))
        let state = CaptureState(file: file, windowFrames: windowFrames)

        // The tap fires on a realtime audio thread. Mark the block `@Sendable` so it
        // is non-isolated: without this the compiler infers `@MainActor` isolation
        // from the enclosing actor and the Swift 6 runtime traps (SIGTRAP) when
        // AVFoundation invokes it off the main thread. `state` is `Sendable`.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            state.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed("starting engine: \(error)")
        }

        self.state = state
        wavURL = url
    }

    func stop() -> RecordingCapture {
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

        state = nil  // flushes and closes the AVAudioFile
        wavURL = nil
        sampleRate = 0

        energyDump.write(snapshot.windowEnergies)
        return RecordingCapture(wav: url, duration: duration, windowEnergies: snapshot.windowEnergies)
    }
}

/// Accumulation for the audio tap: the file write plus the per-window RMS sequence
/// and the frame count. The tap fires on a real-time thread; `snapshot` is read on
/// the main actor after the tap is removed.
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
    private let file: AVAudioFile
    /// Frames per energy window, at the device's native sample rate.
    private let windowFrames: Int

    // Tap-only state. See the note above on why it carries no lock.
    private var windowEnergies: [Float] = []
    /// The window currently filling: sum of squared samples, how many samples went
    /// into that sum, and how many frames it has taken.
    private var windowSquares: Float = 0
    private var windowSquareCount = 0
    private var windowFilled = 0

    // Shared counters, guarded by `lock`.
    private var frames: AVAudioFrameCount = 0
    private var droppedWrites = 0

    init(file: AVAudioFile, windowFrames: Int) {
        self.file = file
        self.windowFrames = windowFrames
        // A minute of headroom, so the common recording never reallocates on the
        // audio thread. Past it, doubling makes a growth a rare event, not a
        // per-window one.
        windowEnergies.reserveCapacity(Int(60 / RecordingCapture.windowDuration))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Cannot throw off the real-time tap; count a failed write so the loss is
        // reported, not silently swallowed.
        var didWrite = true
        do { try file.write(from: buffer) } catch { didWrite = false }
        accumulate(buffer)
        lock.lock()
        frames += buffer.frameLength
        if !didWrite { droppedWrites += 1 }
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

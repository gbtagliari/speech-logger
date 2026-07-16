import AVFoundation
import SpeechLoggerCore
import os

/// Captures the microphone to a native wav in a temp file via `AVAudioEngine`,
/// streamed frame-by-frame so RAM stays O(1) regardless of length (SPEC "The
/// pipeline"). The recorded wav feeds `ffmpeg`, which downmixes to mono/16 kHz —
/// the app records native and does not resample itself.
///
/// While recording it accumulates the two measurements the dual guard needs: the
/// peak sample amplitude and the frame count (for duration). The audio tap runs on
/// a real-time thread, so that state lives behind a lock in `CaptureState`.
@MainActor final class AudioRecorder: AudioRecording {
    enum RecorderError: Error {
        case microphoneAccessDenied
        case engineFailed(String)
    }

    private let log = Logger(subsystem: "app.speech-logger", category: "recorder")
    private let engine = AVAudioEngine()
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
        let state = CaptureState(file: file)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
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

        let snapshot = state?.snapshot ?? (peak: 0, frames: 0, droppedWrites: 0)
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

        return RecordingCapture(wav: url, duration: duration, peak: snapshot.peak)
    }
}

/// Thread-safe accumulation for the audio tap: the file write plus the running
/// peak and frame count. The tap fires on a real-time thread; `snapshot` is read
/// on the main actor after the tap is removed.
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private var peak: Float = 0
    private var frames: AVAudioFrameCount = 0
    private var droppedWrites = 0

    init(file: AVAudioFile) { self.file = file }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Cannot throw off the real-time tap; count a failed write so the loss is
        // reported, not silently swallowed.
        var didWrite = true
        do { try file.write(from: buffer) } catch { didWrite = false }
        let bufferPeak = Self.peak(of: buffer)
        lock.lock()
        peak = max(peak, bufferPeak)
        frames += buffer.frameLength
        if !didWrite { droppedWrites += 1 }
        lock.unlock()
    }

    var snapshot: (peak: Float, frames: AVAudioFrameCount, droppedWrites: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (peak, frames, droppedWrites)
    }

    /// Max absolute sample across all channels. `AVAudioEngine` input is float32,
    /// so `floatChannelData` is present; a non-float format (not seen in practice)
    /// yields 0 and the dual guard would flag silence — acceptable, and loud.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var maxAbs: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<frameLength {
                maxAbs = max(maxAbs, abs(samples[frame]))
            }
        }
        return maxAbs
    }
}

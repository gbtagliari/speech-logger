import AVFoundation
import os

/// Accumulation for the audio tap: the file write plus the per-window RMS sequence
/// and the frame counts. The tap fires on a real-time thread; `snapshot` is read on
/// the main actor after the tap is removed, and `frameCount` is read there every tick
/// while the capture is live.
///
/// **It knows nothing about the format until audio arrives.** The wav is opened, the
/// energy window is sized and the sample rate is recorded on the *first buffer*, from
/// that buffer's own format (#63). Everything the engine claims before then is a
/// resolution, not a fact: on a Bluetooth headset mid-handshake the input node reports
/// 44.1 kHz for a device that supports only 16 kHz, and a wav opened against that number
/// would reject every buffer the device later delivers. One file open happens on the
/// audio thread as a result, once per capture, at a moment where the capture has already
/// spent a second waiting for the device.
///
/// Windows are fixed and span buffer boundaries: a window's partial sum carries over
/// to the next buffer and closes when `windowFrames` frames have gone into it. The
/// tap's `bufferSize` is a hint AVFoundation is free to ignore, so measuring per
/// buffer would leave the window size at the mercy of the device.
///
/// **Why `append` holds the lock throughout**, where it once did the per-sample fold and
/// the file write outside it. A capture can now be rebuilt mid-flight, and `removeTap`
/// does not promise that an in-flight tap block has returned, so two tap blocks — the
/// dying engine's and the fresh one's — can briefly overlap. Two writers means the
/// lock-free reasoning no longer holds, and `AVAudioFile` is not thread-safe either.
///
/// The lock is `OSAllocatedUnfairLock` and not `NSLock` for exactly that reason: the
/// critical section now spans a file write, and the threads contending for it are
/// real-time audio threads. `os_unfair_lock` records its owner and donates priority,
/// so a waiting audio thread cannot be left blocked behind a descheduled holder — which
/// is the one failure an `NSLock` here could produce, at the precise moment the recording
/// matters.
final class CaptureState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    /// Where the wav goes, once a buffer has told us what format to open it in.
    private let wav: URL
    /// How long one energy window spans. Turned into a frame count by the first buffer.
    private let windowDuration: TimeInterval

    // MARK: State under `lock`. Written by the tap, read on the main actor.

    /// The wav being written, opened by the first buffer.
    private var file: AVAudioFile?
    /// Why opening the wav failed, if it did. Kept rather than discarded: the tap cannot
    /// log (it is a real-time thread) and cannot throw (nobody is listening), so the
    /// reason rides out in `snapshot` and is logged by the caller. `droppedWrites` alone
    /// would report the symptom and lose the cause.
    private var openFailure: String?
    /// Frames per energy window, at the rate the audio actually arrived at.
    private var windowFrames = 0
    /// The rate the audio arrived at, and so the one the duration divides by. Zero until
    /// a buffer says otherwise.
    private var sampleRate: Double = 0
    private var windowEnergies: [Float] = []
    /// The window currently filling: sum of squared samples, how many samples went
    /// into that sum, and how many frames it has taken.
    private var windowSquares: Float = 0
    private var windowSquareCount = 0
    private var windowFilled = 0
    /// Frames the device *delivered*. The dead-capture axis reads this: zero means the
    /// tap was never called, whatever happened to the file afterwards (#54).
    private var frames: AVAudioFrameCount = 0
    /// Frames that actually reached the wav. Equal to `frames` on every healthy capture,
    /// and lower only when a write was lost — which is what the duration must be measured
    /// against, since the duration describes the audio the pipeline will transcribe.
    private var writtenFrames: AVAudioFrameCount = 0
    private var droppedWrites = 0

    init(wav: URL, windowDuration: TimeInterval) {
        self.wav = wav
        self.windowDuration = windowDuration
        // A minute of headroom, so the common recording never reallocates on the
        // audio thread. Past it, doubling makes a growth a rare event, not a
        // per-window one.
        windowEnergies.reserveCapacity(Int(60 / windowDuration))
    }

    /// How many frames have arrived. The watchdog's second signal, read once per tick on
    /// the main actor: an engine that reports itself running while this number stands
    /// still is the failure shape that has nothing else to give it away (#63).
    var frameCount: AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// One buffer, from the audio thread. Sizes everything on the first one, then folds,
    /// counts and writes.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        adopt(buffer.format)
        accumulate(buffer)
        frames += buffer.frameLength

        // Cannot throw off the real-time tap; a lost write is counted so it is reported
        // rather than silently swallowed. A buffer with no file behind it is the same
        // loss and counts the same way — the wav could not be opened at all, or a rebuild
        // resolved a format this one was not opened against.
        let didWrite = if let file { (try? file.write(from: buffer)) != nil } else { false }
        if didWrite {
            writtenFrames += buffer.frameLength
        } else {
            droppedWrites += 1
        }
    }

    /// Take the format from the first buffer that arrives: it decides the wav, the window
    /// size and the rate the duration divides by. A no-op on every buffer after.
    ///
    /// Called with `lock` held.
    private func adopt(_ format: AVAudioFormat) {
        guard sampleRate == 0 else { return }
        sampleRate = format.sampleRate
        windowFrames = max(1, Int((format.sampleRate * windowDuration).rounded()))
        do {
            file = try AVAudioFile(forWriting: wav, settings: format.settings)
        } catch {
            // Kept, not swallowed: every buffer then counts as a dropped write, and the
            // capture comes back with its energy measurements and no audio, which the
            // guard already knows how to judge — but the reason it happened is only
            // knowable here.
            openFailure = String(describing: error)
        }
    }

    /// The trailing partial window is included: dropping it would throw away up to
    /// 20 ms, which is a fifth of a 100 ms utterance's evidence.
    var snapshot: CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let trailing =
            windowSquareCount > 0
            ? [(windowSquares / Float(windowSquareCount)).squareRoot()] : []
        return CaptureSnapshot(
            windowEnergies: windowEnergies + trailing, frames: frames,
            writtenFrames: writtenFrames, droppedWrites: droppedWrites,
            sampleRate: sampleRate, openFailure: openFailure)
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
    ///
    /// Called with `lock` held.
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

/// What a finished capture measured, read off the main actor once the tap is gone.
///
/// The two frame counts are not redundant. `frames` is what the *device delivered* and is
/// the dead-capture axis (#54): zero means the tap was never called. `writtenFrames` is
/// what reached the wav, and is what the duration is measured from, because the duration
/// describes the audio the pipeline is about to transcribe rather than the audio that went
/// past. They differ only when a write was lost.
struct CaptureSnapshot {
    let windowEnergies: [Float]
    let frames: AVAudioFrameCount
    let writtenFrames: AVAudioFrameCount
    let droppedWrites: Int
    /// The rate the audio actually arrived at, or zero if none did.
    let sampleRate: Double
    /// Why the wav could never be opened, if it could not.
    let openFailure: String?

    /// The empty measurement, for a `stop` with no capture behind it. Not named `none`:
    /// at the `??` that reads it, that spelling collides with `Optional.none`.
    static let empty = CaptureSnapshot(
        windowEnergies: [], frames: 0, writtenFrames: 0, droppedWrites: 0, sampleRate: 0,
        openFailure: nil)
}

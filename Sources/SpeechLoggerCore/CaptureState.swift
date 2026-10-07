import AVFoundation
import os

/// Accumulation for the audio tap: the conversion to the capture format, the file write, the
/// per-window RMS sequence and the frame counts. The tap fires on a real-time thread;
/// `snapshot` is read on the main actor after the tap is removed, and `frameCount` is read
/// there every tick while the capture is live.
///
/// **Every buffer is converted to one fixed format, `format`, before it is measured or
/// written** (#69). The device's format is not a constant of the capture: on macOS 27 a
/// Bluetooth headset delivers 44.1 kHz buffers and then 16 kHz ones once the HFP link settles
/// and the engine is rebuilt. A wav opened at the first buffer's rate took the later buffers
/// without complaint (`AVAudioFile` accepts a buffer that differs only in rate) and played back
/// 2.75x too fast. So the wav is opened up front in the fixed format, and a converter is built
/// for whatever format arrives and rebuilt whenever it changes.
///
/// Windows are fixed and span buffer boundaries: a window's partial sum carries over to the
/// next buffer and closes after `windowFrames` converted frames. The tap's `bufferSize` is a
/// hint AVFoundation is free to ignore, so measuring per buffer would leave the window size
/// at the mercy of the device.
///
/// **Why `append` holds the lock throughout.** A capture can be rebuilt mid-flight, and
/// `removeTap` does not promise that an in-flight tap block has returned, so two tap blocks
/// (the dying engine's and the fresh one's) can briefly overlap. `AVAudioFile` and
/// `AVAudioConverter` are not thread-safe either.
///
/// The lock is `OSAllocatedUnfairLock` and not `NSLock` because the critical section spans a
/// conversion and a file write, and the threads contending for it are real-time audio
/// threads. `os_unfair_lock` records its owner and donates priority, so a waiting audio
/// thread cannot be left blocked behind a descheduled holder.
public final class CaptureState: @unchecked Sendable {
    /// What every capture is converted to, measured in and written as. 16 kHz mono is what
    /// the encode contract (ADR-0002) and Whisper want anyway, so nothing downstream
    /// resamples a second time.
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private static let windowFrames = Int(
        (format.sampleRate * RecordingCapture.windowDuration).rounded())

    private let lock = OSAllocatedUnfairLock()

    // MARK: State under `lock`. Written by the tap, read on the main actor.

    /// The wav being written, opened at `init`. Nil when it could not be opened.
    private var file: AVAudioFile?
    /// Why opening the wav failed, if it did. The tap cannot log (real-time thread) and
    /// cannot throw (nobody is listening), so the reason rides out in `snapshot`.
    private let openFailure: String?
    /// Built for the format the device is delivering now; rebuilt when that changes.
    private var converter: AVAudioConverter?
    /// A format no converter could be built for, so its buffers are dropped without retrying
    /// the build (and allocating) on every one of them.
    private var unconvertible: AVAudioFormat?
    /// The first reason a buffer could not be converted. Kept like `openFailure`.
    private var conversionFailure: String?
    /// The converter's output, reused across buffers so the steady state does not allocate
    /// on the audio thread. Replaced only when an input needs more room.
    private var converted: AVAudioPCMBuffer?
    private var windowEnergies: [Float] = []
    /// The window currently filling: sum of squared samples and how many went into it.
    private var windowSquares: Float = 0
    private var windowFilled = 0
    /// Frames the device *delivered*, at its own rate. The dead-capture axis reads this:
    /// zero means the tap was never called, whatever happened afterwards (#54).
    private var deliveredFrames: AVAudioFrameCount = 0
    /// Converted frames that reached the wav, in `format`. The duration is measured from
    /// this, since it describes the audio the pipeline will transcribe.
    private var writtenFrames: AVAudioFrameCount = 0
    private var droppedBuffers = 0

    public init(wav: URL) {
        do {
            file = try AVAudioFile(
                forWriting: wav, settings: Self.format.settings,
                commonFormat: Self.format.commonFormat, interleaved: Self.format.isInterleaved)
            openFailure = nil
        } catch {
            // Kept, not swallowed: every buffer then counts as a dropped write, and the
            // capture comes back with its energy measurements and no audio, which the guard
            // already knows how to judge.
            file = nil
            openFailure = String(describing: error)
        }
        // A minute of headroom, so the common recording never reallocates on the audio
        // thread. Past it, doubling makes a growth a rare event, not a per-window one.
        windowEnergies.reserveCapacity(Int(60 / RecordingCapture.windowDuration))
    }

    /// How many frames the device has delivered. The watchdog's second signal, read once per
    /// tick on the main actor (#63).
    public var frameCount: AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        return deliveredFrames
    }

    /// One buffer, from the audio thread: converted, measured, written.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        deliveredFrames += buffer.frameLength
        guard let converter = converter(for: buffer) else {
            // A format no converter takes (not seen in practice): the buffer is lost, and
            // counted so it is reported rather than silently swallowed.
            droppedBuffers += 1
            return
        }
        convert(buffer, with: converter)
    }

    /// The trailing partial window is included: dropping it would throw away up to 20 ms,
    /// which is a fifth of a 100 ms utterance's evidence.
    public var snapshot: CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let trailing = windowFilled > 0 ? [windowRMS] : []
        return CaptureSnapshot(
            windowEnergies: windowEnergies + trailing, deliveredFrames: deliveredFrames,
            writtenFrames: writtenFrames, droppedBuffers: droppedBuffers,
            openFailure: openFailure, conversionFailure: conversionFailure)
    }

    // MARK: - Conversion. Called with `lock` held.

    /// The converter for this buffer's format, rebuilding it when the device changed rate or
    /// channel count. The old converter's buffered tail is drained first, so the switch costs
    /// at most the resampler's few milliseconds of latency rather than its whole history.
    private func converter(for buffer: AVAudioPCMBuffer) -> AVAudioConverter? {
        if let converter, converter.inputFormat == buffer.format { return converter }
        if unconvertible == buffer.format { return nil }
        if let converter { drain(converter) }
        converter = AVAudioConverter(from: buffer.format, to: Self.format)
        if converter == nil {
            unconvertible = buffer.format
            conversionFailure = conversionFailure ?? "no converter from \(buffer.format)"
        }
        return converter
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        guard let output = outputBuffer(forInput: buffer) else {
            droppedBuffers += 1
            return
        }
        var delivered = false
        pump(converter, into: output) { _, status in
            if delivered {
                // Not end-of-stream: a resampler keeps a tail it releases on the next buffer.
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// Flush what the converter still holds, before it is replaced.
    private func drain(_ converter: AVAudioConverter) {
        guard let output = converted else { return }
        pump(converter, into: output) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    /// Run the converter until it has nothing more to give for the input it was offered,
    /// handing every chunk it produces to `consume`.
    private func pump(
        _ converter: AVAudioConverter, into output: AVAudioPCMBuffer,
        input: AVAudioConverterInputBlock
    ) {
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            if status == .error {
                droppedBuffers += 1
                conversionFailure = conversionFailure ?? error.map(String.init(describing:))
                return
            }
            if output.frameLength > 0 { consume(output) }
            // `haveData` with a full buffer means there may be more; anything else means
            // the converter is waiting for input or done.
            guard status == .haveData, output.frameLength == output.frameCapacity else { return }
        }
    }

    /// Room for everything one input buffer converts to, plus slack for the resampler's
    /// carry-over. Grows, never shrinks, so after the first buffer of a format this is a
    /// pointer read.
    private func outputBuffer(forInput buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let needed = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        if let converted, converted.frameCapacity >= needed { return converted }
        converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: needed)
        return converted
    }

    private func consume(_ chunk: AVAudioPCMBuffer) {
        accumulate(chunk)
        // Cannot throw off the real-time tap; a lost write is counted so it is reported. A
        // chunk with no file behind it is the same loss and counts the same way.
        let didWrite = if let file { (try? file.write(from: chunk)) != nil } else { false }
        if didWrite {
            writtenFrames += chunk.frameLength
        } else {
            droppedBuffers += 1
        }
    }

    /// Fold the mono chunk into the window sequence, closing a window every `windowFrames`
    /// frames. Measured after the downmix, so a stereo device with one dead channel halves
    /// the energy rather than reporting the louder channel; the guard's floor is relative to
    /// the recording's own noise (#67), so that margin needs no recalibration.
    private func accumulate(_ chunk: AVAudioPCMBuffer) {
        guard let samples = chunk.floatChannelData?[0] else { return }
        for frame in 0..<Int(chunk.frameLength) {
            let sample = samples[frame]
            windowSquares += sample * sample
            windowFilled += 1
            if windowFilled >= Self.windowFrames {
                windowEnergies.append(windowRMS)
                windowSquares = 0
                windowFilled = 0
            }
        }
    }

    private var windowRMS: Float { (windowSquares / Float(windowFilled)).squareRoot() }
}

/// What a finished capture measured, read off the main actor once the tap is gone.
///
/// The two frame counts are not in the same unit. `deliveredFrames` is what the device
/// delivered, at whatever rate it ran, and is the dead-capture axis (#54): zero means the tap
/// was never called. `writtenFrames` is what reached the wav, in `CaptureState.format`, and is
/// what the duration is measured from.
public struct CaptureSnapshot: Sendable {
    public let windowEnergies: [Float]
    public let deliveredFrames: AVAudioFrameCount
    public let writtenFrames: AVAudioFrameCount
    /// Buffers (or converted chunks) that never reached the wav, whatever stopped them.
    public let droppedBuffers: Int
    /// Why the wav could never be opened, if it could not.
    public let openFailure: String?
    /// Why a buffer could not be converted, the first time one could not.
    public let conversionFailure: String?

    public var duration: TimeInterval {
        Double(writtenFrames) / CaptureState.format.sampleRate
    }

    /// The empty measurement, for a `stop` with no capture behind it. Not named `none`: at
    /// the `??` that reads it, that spelling collides with `Optional.none`.
    public static let empty = CaptureSnapshot(
        windowEnergies: [], deliveredFrames: 0, writtenFrames: 0, droppedBuffers: 0,
        openFailure: nil, conversionFailure: nil)
}

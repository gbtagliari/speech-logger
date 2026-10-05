import AVFoundation
import Foundation
import Testing

@testable import SpeechLoggerCore

/// The capture accumulator (#69): whatever format the device delivers, and however often it
/// changes it mid-capture, the wav, the duration and the energy windows are in one fixed
/// format, 16 kHz mono.
///
/// The regression is a Bluetooth headset on macOS 27 that delivers 44.1 kHz buffers and then
/// 16 kHz ones inside one capture. Written into a wav opened at the first rate, the audio
/// played back 2.75x too fast.
struct CaptureStateTests {
    private static let rate = CaptureState.format.sampleRate
    private static let window = RecordingCapture.windowDuration

    // MARK: - A format change mid-capture

    @Test("a 44.1 kHz stereo run followed by a 16 kHz mono run lands as one 16 kHz mono wav")
    func formatSwitchKeepsOneFormat() throws {
        let capture = try Capture.recorded([
            .sine(rate: 44_100, channels: 2, frequency: 440, seconds: 1.0),
            .sine(rate: 16_000, channels: 1, frequency: 440, seconds: 1.5),
        ])

        #expect(capture.wavFormat.sampleRate == Self.rate)
        #expect(capture.wavFormat.channelCount == 1)
        #expect(abs(capture.wavSeconds - 2.5) <= Self.window)
    }

    @Test("the tone's pitch survives the switch, so the audio is not sped up")
    func formatSwitchPreservesPitch() throws {
        let capture = try Capture.recorded([
            .sine(rate: 44_100, channels: 2, frequency: 440, seconds: 1.0),
            .sine(rate: 16_000, channels: 1, frequency: 440, seconds: 1.0),
        ])

        // A 440 Hz sine crosses zero 880 times a second. Played 2.75x fast it would read
        // ~2420, so a tolerance of a few percent separates the two outright.
        let crossings = capture.zeroCrossingsPerSecond
        #expect(abs(crossings - 880) < 880 * 0.03, "measured \(crossings) crossings/s")
    }

    @Test("the energy windows span 20 ms on both sides of the switch")
    func windowsFollowTheFixedFormat() throws {
        let capture = try Capture.recorded([
            .sine(rate: 44_100, channels: 2, frequency: 440, seconds: 1.0),
            .sine(rate: 16_000, channels: 1, frequency: 440, seconds: 1.0),
        ])

        let expected = 2.0 / Self.window
        #expect(abs(Double(capture.snapshot.windowEnergies.count) - expected) <= 2)
    }

    @Test("the snapshot's duration is the wav's length")
    func durationMatchesTheWav() throws {
        let capture = try Capture.recorded([
            .sine(rate: 48_000, channels: 2, frequency: 440, seconds: 0.7),
            .sine(rate: 16_000, channels: 1, frequency: 440, seconds: 0.4),
        ])

        #expect(
            abs(capture.snapshot.duration - capture.wavSeconds) < 1 / Self.rate * 2,
            "snapshot \(capture.snapshot.duration) s, wav \(capture.wavSeconds) s")
        #expect(abs(capture.snapshot.duration - 1.1) <= Self.window)
    }

    @Test("frames count what the device delivered, at the device's own rate")
    func framesCountDeliveredFrames() throws {
        let capture = try Capture.recorded([
            .sine(rate: 44_100, channels: 2, frequency: 440, seconds: 1.0),
            .sine(rate: 16_000, channels: 1, frequency: 440, seconds: 1.0),
        ])

        #expect(capture.snapshot.frames == 44_100 + 16_000)
    }

    @Test("a loud stereo channel and a dead one still measure as sound after the downmix")
    func downmixIsMeasured() throws {
        let capture = try Capture.recorded([
            .sine(rate: 44_100, channels: 2, frequency: 440, seconds: 0.5, deadChannels: [1])
        ])

        let loud = capture.snapshot.windowEnergies.dropFirst().filter { $0 > 0.1 }
        #expect(loud.count >= capture.snapshot.windowEnergies.count - 2)
    }

    // MARK: - Nothing arrived

    @Test("no buffers leaves an empty snapshot with zero frames, so a dead capture still reads")
    func noBuffersIsEmpty() throws {
        let capture = try Capture.recorded([])

        #expect(capture.snapshot.frames == 0)
        #expect(capture.snapshot.writtenFrames == 0)
        #expect(capture.snapshot.windowEnergies.isEmpty)
        #expect(capture.snapshot.duration == 0)
        #expect(capture.snapshot.droppedWrites == 0)
    }

    // MARK: - The wav cannot be opened

    @Test("an unwritable wav location is reported, and every buffer counts as a dropped write")
    func unwritableWavIsReported() {
        let wav = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/capture.wav")
        let state = CaptureState(wav: wav)
        for buffer in Tone.sine(rate: 16_000, channels: 1, frequency: 440, seconds: 0.5).buffers {
            state.append(buffer)
        }
        let snapshot = state.snapshot

        #expect(snapshot.openFailure != nil)
        #expect(snapshot.droppedWrites > 0)
        #expect(snapshot.writtenFrames == 0)
        #expect(snapshot.duration == 0)
        #expect(snapshot.frames == 8_000)
        // The energy still measures: the guard judges it like any other capture.
        #expect(!snapshot.windowEnergies.isEmpty)
    }
}

// MARK: - Fixtures

/// A synthetic device run: one format, delivered in tap-sized buffers.
private struct Tone {
    let buffers: [AVAudioPCMBuffer]

    static func sine(
        rate: Double, channels: AVAudioChannelCount, frequency: Double, seconds: Double,
        deadChannels: Set<Int> = []
    ) -> Tone {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels,
            interleaved: false)!
        let total = Int((rate * seconds).rounded())
        let chunk = 4096
        var buffers: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < total {
            let length = min(chunk, total - offset)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            buffer.frameLength = AVAudioFrameCount(length)
            for channel in 0..<Int(channels) {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<length {
                    let t = Double(offset + frame) / rate
                    samples[frame] =
                        deadChannels.contains(channel) ? 0 : Float(0.5 * sin(2 * .pi * frequency * t))
                }
            }
            buffers.append(buffer)
            offset += length
        }
        return Tone(buffers: buffers)
    }
}

/// A finished capture, read back the way the pipeline would: the snapshot, and the wav on
/// disk once the accumulator has let go of it.
private struct Capture {
    let snapshot: CaptureSnapshot
    let wavFormat: AVAudioFormat
    let samples: [Float]

    var wavSeconds: Double { Double(samples.count) / wavFormat.sampleRate }

    var zeroCrossingsPerSecond: Double {
        // The first and last windows hold converter priming and the switch's seam; the
        // middle is what the pitch is read from.
        let margin = Int(wavFormat.sampleRate * 0.05)
        let body = samples.dropFirst(margin).dropLast(margin)
        var crossings = 0
        var previous = body.first ?? 0
        for sample in body.dropFirst() {
            if (previous < 0) != (sample < 0) { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(body.count) / wavFormat.sampleRate)
    }

    static func recorded(_ tones: [Tone]) throws -> Capture {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-state-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        let snapshot = feed(tones, to: wav)

        let file = try AVAudioFile(forReading: wav)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples: [Float] = []
        // `read(into:)` may return fewer frames than asked for, so one call is not the file.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return Capture(snapshot: snapshot, wavFormat: file.fileFormat, samples: samples)
    }

    /// Its own function so the accumulator is released, and the wav closed, on return.
    private static func feed(_ tones: [Tone], to wav: URL) -> CaptureSnapshot {
        let state = CaptureState(wav: wav)
        for buffer in tones.flatMap(\.buffers) {
            state.append(buffer)
        }
        return state.snapshot
    }
}

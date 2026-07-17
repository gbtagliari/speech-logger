import Foundation

/// A tiny silent wav, synthesized in memory.
///
/// It exists for one job: `mlx_whisper`'s CLI takes an audio file, so the preflight
/// model download (`WhisperModelDownloader`) needs *something* to hand it. Silence is
/// the cheapest thing that decodes, and its transcript is thrown away — the run is
/// for the download, not the text. 16 kHz mono is Whisper's own working format, so
/// `ffmpeg` decodes it without resampling.
enum SilentWAV {
    static let sampleRate = 16_000
    private static let bitsPerSample = 16
    private static let channels = 1

    /// `seconds` of digital silence as a canonical 44-byte-header PCM wav.
    static func data(seconds: Double) -> Data {
        let frames = max(1, Int((Double(sampleRate) * seconds).rounded()))
        let bytesPerFrame = channels * bitsPerSample / 8
        let dataSize = frames * bytesPerFrame

        var wav = Data()
        wav.append(ascii: "RIFF")
        wav.append(littleEndian: UInt32(36 + dataSize))  // everything after this field
        wav.append(ascii: "WAVE")

        wav.append(ascii: "fmt ")
        wav.append(littleEndian: UInt32(16))  // PCM fmt chunk size
        wav.append(littleEndian: UInt16(1))  // PCM, uncompressed
        wav.append(littleEndian: UInt16(channels))
        wav.append(littleEndian: UInt32(sampleRate))
        wav.append(littleEndian: UInt32(sampleRate * bytesPerFrame))  // byte rate
        wav.append(littleEndian: UInt16(bytesPerFrame))  // block align
        wav.append(littleEndian: UInt16(bitsPerSample))

        wav.append(ascii: "data")
        wav.append(littleEndian: UInt32(dataSize))
        wav.append(Data(count: dataSize))  // silence is zeroes
        return wav
    }
}

extension Data {
    fileprivate mutating func append(ascii text: String) {
        append(contentsOf: Array(text.utf8))
    }

    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        // Qualified: inside a `Data` extension the bare name resolves to Data's own
        // `withUnsafeBytes`, which reads the buffer instead of writing this integer.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

import Foundation

/// A ULID: a 26-character, timestamp-sortable identifier (Crockford base32).
///
/// The item directory name must sort lexicographically by creation time so the
/// log can be listed in order straight off the filesystem (ADR-0003); a random
/// `UUIDv4` cannot do that. A ULID is a 48-bit millisecond timestamp (10 chars)
/// followed by 80 bits of randomness (16 chars). Crockford base32's alphabet is
/// already in value order, so a plain string sort of ULIDs is a time sort.
///
/// Hand-rolled rather than pulled from a package: the spec forbids copyleft
/// dependencies and a permissive one is not worth a dependency for ~40 lines.
public enum ULID {
    /// Crockford base32 alphabet — excludes I, L, O, U; ordered so lexical sort == value sort.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The fixed ULID length: 10 timestamp chars + 16 randomness chars.
    public static let length = 26

    /// Generate a ULID for `timestamp`, drawing 10 random bytes from `randomByte`.
    ///
    /// `randomByte` is injected so tests can produce deterministic ids; production
    /// passes a system RNG.
    public static func generate(
        timestamp: Date,
        randomByte: () -> UInt8
    ) -> String {
        let millis = UInt64((timestamp.timeIntervalSince1970 * 1000).rounded())
        return encodeTimestamp(millis) + encodeRandomness(randomByte)
    }

    /// Generate a ULID for `timestamp` with cryptographically-strong randomness.
    public static func generate(timestamp: Date) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(timestamp: timestamp, randomByte: { UInt8.random(in: .min ... .max, using: &rng) })
    }

    /// Encode the low 48 bits of `millis` as 10 base32 characters, most significant first.
    private static func encodeTimestamp(_ millis: UInt64) -> String {
        var value = millis & 0xFFFF_FFFF_FFFF // 48 bits
        var chars = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            chars[i] = alphabet[Int(value & 0x1F)]
            value >>= 5
        }
        return String(chars)
    }

    /// Encode 80 bits (10 bytes) of randomness as 16 base32 characters.
    private static func encodeRandomness(_ randomByte: () -> UInt8) -> String {
        // 10 bytes = 80 bits = exactly 16 groups of 5 bits. Keep only the
        // unconsumed low bits in `buffer` (masked after each emit) so it never
        // overflows; pull 5 bits at a time, most significant first.
        var buffer: UInt32 = 0
        var bits = 0
        var out = ""
        var produced = 0
        var bytesTaken = 0
        while produced < 16 {
            if bits < 5, bytesTaken < 10 {
                buffer = (buffer << 8) | UInt32(randomByte())
                bits += 8
                bytesTaken += 1
                continue
            }
            bits -= 5
            let index = Int((buffer >> UInt32(bits)) & 0x1F)
            out.append(alphabet[index])
            buffer &= (UInt32(1) << UInt32(bits)) - 1
            produced += 1
        }
        return out
    }
}

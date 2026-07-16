import Foundation
import Testing

@testable import SpeechLoggerCore

/// The item directory name must sort lexicographically by creation time (ADR-0003),
/// so the log lists in order straight off the filesystem. These pin that contract.
struct ULIDTests {
    @Test("a ULID is 26 Crockford-base32 characters")
    func shapeIs26Base32Chars() {
        let ulid = ULID.generate(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ulid.count == ULID.length)
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        #expect(ulid.allSatisfy { allowed.contains($0) })
    }

    @Test("a later timestamp sorts after an earlier one, regardless of randomness")
    func lexicalSortIsTimeSort() {
        // Same all-zero randomness isolates the timestamp prefix.
        let earlier = ULID.generate(timestamp: Date(timeIntervalSince1970: 1_700_000_000), randomByte: { 0 })
        let later = ULID.generate(timestamp: Date(timeIntervalSince1970: 1_700_000_001), randomByte: { 0 })
        #expect(earlier < later)
    }

    @Test("even a max-randomness earlier id sorts before a min-randomness later id")
    func timestampDominatesRandomness() {
        let earlierMaxRandom = ULID.generate(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), randomByte: { 0xFF })
        let laterMinRandom = ULID.generate(
            timestamp: Date(timeIntervalSince1970: 1_700_000_001), randomByte: { 0 })
        #expect(earlierMaxRandom < laterMinRandom)
    }

    @Test("the same-millisecond ids differ by randomness")
    func randomnessDisambiguatesWithinAMillisecond() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ULID.generate(timestamp: ts, randomByte: { 0 })
        let b = ULID.generate(timestamp: ts, randomByte: { 0xFF })
        #expect(a != b)
        // The 10-char timestamp prefix is identical; only the randomness suffix differs.
        #expect(a.prefix(10) == b.prefix(10))
        #expect(a.suffix(16) != b.suffix(16))
    }

    @Test("all-zero randomness encodes to sixteen zero characters")
    func zeroRandomnessSuffix() {
        let ulid = ULID.generate(timestamp: Date(timeIntervalSince1970: 0), randomByte: { 0 })
        #expect(ulid.suffix(16) == "0000000000000000")
    }
}

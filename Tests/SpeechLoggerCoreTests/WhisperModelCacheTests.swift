import Foundation
import Testing

@testable import SpeechLoggerCore

/// The Whisper model cache probe: where HuggingFace keeps the ~1.5 GB
/// `whisper-large-v3-turbo` download, and whether it is actually there. Preflight's
/// "model downloaded" check is this, and nothing else (no `mlx_whisper` run).
struct WhisperModelCacheTests {
    // MARK: - Locating the hub

    @Test("the hub defaults to ~/.cache/huggingface/hub")
    func hubDefaultsUnderHome() {
        let cache = WhisperModelCache.resolve(environment: [:], home: "/Users/x")
        #expect(cache.hub.path == "/Users/x/.cache/huggingface/hub")
    }

    @Test("HF_HUB_CACHE wins over every other source")
    func hubCacheEnvWins() {
        let cache = WhisperModelCache.resolve(
            environment: ["HF_HUB_CACHE": "/tmp/a", "HF_HOME": "/tmp/b", "XDG_CACHE_HOME": "/tmp/c"],
            home: "/Users/x")
        #expect(cache.hub.path == "/tmp/a")
    }

    @Test("HF_HOME puts the hub under HF_HOME/hub")
    func hfHomeIsHubsParent() {
        let cache = WhisperModelCache.resolve(environment: ["HF_HOME": "/tmp/b"], home: "/Users/x")
        #expect(cache.hub.path == "/tmp/b/hub")
    }

    @Test("XDG_CACHE_HOME moves the whole cache, hub included")
    func xdgCacheHome() {
        let cache = WhisperModelCache.resolve(environment: ["XDG_CACHE_HOME": "/tmp/c"], home: "/Users/x")
        #expect(cache.hub.path == "/tmp/c/huggingface/hub")
    }

    @Test("an empty env var is ignored, not honoured as an empty path")
    func emptyEnvVarIgnored() {
        let cache = WhisperModelCache.resolve(environment: ["HF_HUB_CACHE": ""], home: "/Users/x")
        #expect(cache.hub.path == "/Users/x/.cache/huggingface/hub")
    }

    @Test("the repo directory is the model id with slashes flattened")
    func repoDirectoryName() {
        let cache = WhisperModelCache(hub: URL(fileURLWithPath: "/hub"))
        #expect(
            cache.directory(for: "mlx-community/whisper-large-v3-turbo").path
                == "/hub/models--mlx-community--whisper-large-v3-turbo")
    }

    // MARK: - Is it downloaded?

    @Test("a hub with the model's weights under refs/main reads as cached")
    func cachedModelDetected() throws {
        let hub = try HubFixture.makeTemporary()
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    @Test("an absent hub reads as not cached")
    func absentHub() {
        #expect(!WhisperModelCache(hub: HubFixture.temporaryURL()).isCached(model: Transcriber.model))
    }

    @Test("a different model cached does not satisfy ours")
    func otherModelDoesNotCount() throws {
        let hub = try HubFixture.makeTemporary(repo: "models--mlx-community--whisper-tiny")
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(!WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    /// An interrupted download leaves the tree without weights. Checking the directory
    /// alone would call that a hit, and the first dictation would die `HF_HUB_OFFLINE`.
    @Test("a snapshot with no weights reads as not cached")
    func partialDownloadIsNotCached() throws {
        let hub = try HubFixture.makeTemporary(files: ["config.json"])
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(!WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    @Test("a missing refs/main reads as not cached")
    func missingRefIsNotCached() throws {
        let hub = try HubFixture.makeTemporary()
        defer { try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.removeItem(at: HubFixture.ref(in: hub))
        #expect(!WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    @Test("a ref pointing at a snapshot that is not there reads as not cached")
    func danglingRefIsNotCached() throws {
        let hub = try HubFixture.makeTemporary(revision: "abc")
        defer { try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.removeItem(at: HubFixture.snapshot(in: hub, revision: "abc"))
        #expect(!WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    @Test("surrounding whitespace in refs/main is tolerated")
    func refIsTrimmed() throws {
        let hub = try HubFixture.makeTemporary()
        defer { try? FileManager.default.removeItem(at: hub) }
        try Data("a4aaeec\n".utf8).write(to: HubFixture.ref(in: hub))
        #expect(WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }

    /// `refs/main` is attacker-free (it is our own cache) but a malformed one must not
    /// let the probe walk out of the hub and find some unrelated file.
    @Test("a ref that escapes the snapshots directory reads as not cached")
    func traversingRefIsNotCached() throws {
        let hub = try HubFixture.makeTemporary()
        defer { try? FileManager.default.removeItem(at: hub) }
        try Data("../../..".utf8).write(to: HubFixture.ref(in: hub))
        #expect(!WhisperModelCache(hub: hub).isCached(model: Transcriber.model))
    }
}

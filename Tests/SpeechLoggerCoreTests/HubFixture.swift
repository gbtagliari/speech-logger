import Foundation

@testable import SpeechLoggerCore

/// A HuggingFace hub on disk, the shape `huggingface_hub` writes it: a repo directory
/// holding `refs/main` (a commit hash) and `snapshots/<hash>/` (the files).
///
/// Shared because three suites need the same tree — the cache probe, preflight, and
/// the downloader all ask the same question of it — and because the tree's shape is a
/// fact about HuggingFace, so it should be stated once.
enum HubFixture {
    /// The repo directory name for the model the app pins.
    static let pinnedRepo = "models--mlx-community--whisper-large-v3-turbo"

    /// Create a hub at `hub`. Defaults describe a complete download of the pinned
    /// model; pass `files` without `weights.safetensors` for an interrupted one.
    static func create(
        at hub: URL,
        repo: String = pinnedRepo,
        revision: String = "a4aaeec",
        files: [String] = ["config.json", "weights.safetensors"]
    ) throws {
        let root = hub.appendingPathComponent(repo, isDirectory: true)
        let snapshot = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        let refs = root.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: snapshot.appendingPathComponent(file))
        }
        try Data(revision.utf8).write(to: refs.appendingPathComponent("main"))
    }

    /// A fresh hub under a unique temp directory. The caller removes it.
    static func makeTemporary(
        repo: String = pinnedRepo,
        revision: String = "a4aaeec",
        files: [String] = ["config.json", "weights.safetensors"]
    ) throws -> URL {
        let hub = temporaryURL()
        try create(at: hub, repo: repo, revision: revision, files: files)
        return hub
    }

    /// A hub path that does not exist: nothing downloaded.
    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-\(UUID().uuidString)", isDirectory: true)
    }

    /// The `refs/main` file inside a hub, for the malformed-ref cases.
    static func ref(in hub: URL, repo: String = pinnedRepo) -> URL {
        hub.appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("main")
    }

    /// A snapshot directory inside a hub, for the dangling-ref case.
    static func snapshot(in hub: URL, revision: String, repo: String = pinnedRepo) -> URL {
        hub.appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }
}

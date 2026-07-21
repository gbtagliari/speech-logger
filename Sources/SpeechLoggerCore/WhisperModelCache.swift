import Foundation

/// Where HuggingFace keeps `mlx_whisper`'s downloaded model, and whether ours is
/// actually there. This is preflight's "Whisper model downloaded" check.
///
/// It has to be a cache read, not a trial run: transcription ships with
/// `HF_HUB_OFFLINE=1` so a transcription never stalls on the network, which means an
/// uncached model fails outright at capture time. The download is therefore a
/// deliberate preflight step (`WhisperModelDownloader`), and this is how we know
/// whether it is still owed (`docs/research/mlx-whisper-shell-out-contract.md`).
public struct WhisperModelCache: Sendable, Equatable {
    /// The hub directory — `.../huggingface/hub`, one subdirectory per model repo.
    public let hub: URL

    public init(hub: URL) {
        self.hub = hub
    }

    /// The hub as `huggingface_hub` itself resolves it, in its precedence order:
    /// `HF_HUB_CACHE` > `HF_HOME/hub` > `XDG_CACHE_HOME/huggingface/hub` >
    /// `~/.cache/huggingface/hub`. A GUI-launched app inherits none of those vars, so
    /// the default is what ships; the rest exist because the user's own shell (where
    /// the model may already have been downloaded) may set them.
    public static func resolve(environment: [String: String], home: String) -> WhisperModelCache {
        if let hubCache = value(environment["HF_HUB_CACHE"]) {
            return WhisperModelCache(hub: URL(fileURLWithPath: hubCache))
        }
        if let hfHome = value(environment["HF_HOME"]) {
            return WhisperModelCache(
                hub: URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true))
        }
        let cacheHome = value(environment["XDG_CACHE_HOME"]) ?? home + "/.cache"
        return WhisperModelCache(
            hub: URL(fileURLWithPath: cacheHome)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true))
    }

    /// The cache as resolved on the running machine.
    public static let `default` = resolve(
        environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())

    /// The repo directory for a model id: `hub/models--<org>--<name>`, HuggingFace's
    /// flattening of the slash.
    public func directory(for model: String) -> URL {
        let flattened = "models--" + model.replacingOccurrences(of: "/", with: "--")
        return hub.appendingPathComponent(flattened, isDirectory: true)
    }

    /// Whether `model` is downloaded and usable offline.
    ///
    /// The gate is the weights file under the revision `refs/main` names, not the repo
    /// directory: an interrupted download leaves the tree in place without the weights,
    /// and calling that a hit would hand the user a green preflight and a first
    /// transcription that dies on `HF_HUB_OFFLINE`.
    public func isCached(model: String) -> Bool {
        let root = directory(for: model)
        guard let revision = revision(in: root) else { return false }
        let weights = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
            .appendingPathComponent("weights.safetensors")
        return FileManager.default.fileExists(atPath: weights.path)
    }

    /// The commit hash in `refs/main`, or nil if it is absent, empty, or not a single
    /// path component (which would let a malformed ref walk out of `snapshots/`).
    private func revision(in root: URL) -> String? {
        let ref = root
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("main")
        guard let data = try? Data(contentsOf: ref) else { return nil }
        let revision = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty, revision != ".", revision != "..", !revision.contains("/")
        else { return nil }
        return revision
    }

    private static func value(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}

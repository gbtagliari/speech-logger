import Foundation

/// The persistence substrate: log items as directories of plain files, each with
/// an explicit state in `meta.json` (ADR-0003, ADR-0006). Create, list, read,
/// transition, and delete items; recover orphans on boot. No database.
///
/// A value type holding only immutable config — the filesystem *is* the state.
/// Isolated item directories make concurrent work on different items safe with no
/// shared writer or lock (ADR-0003/0006), so no actor is needed. Every write is
/// temp+rename (`Data.write(options: .atomic)`), and the content file for a stage
/// is written before `state` flips, so no half-written content is ever visible.
public struct ItemStore: Sendable {
    /// The `.../items/` directory holding one subdirectory per item.
    public let root: URL
    private let now: @Sendable () -> Date
    private let makeID: @Sendable (Date) -> String

    /// - Parameters:
    ///   - root: the `items/` directory (created on demand).
    ///   - now: injectable clock; production uses the wall clock.
    ///   - makeID: injectable id generator; production uses a ULID from the timestamp.
    public init(
        root: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable (Date) -> String = { ULID.generate(timestamp: $0) }
    ) {
        self.root = root
        self.now = now
        self.makeID = makeID
    }

    /// The production root: `~/Library/Application Support/speech-logger/items/`.
    public static func defaultRoot() throws(StoreError) -> URL {
        let support = try wrap {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        }
        return support
            .appendingPathComponent("speech-logger", isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
    }

    // MARK: - Create

    /// Create a new item at `recording`: a fresh ULID directory with `meta.json`.
    public func create() throws(StoreError) -> Item {
        let created = now()
        let id = makeID(created)
        let dir = directory(for: id)
        try wrap { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let meta = ItemMeta.recording(created: created)
        try writeMeta(meta, for: id)
        return Item(id: id, meta: meta)
    }

    // MARK: - Content files (atomic temp+rename)

    /// Atomically write `data` to `file` inside the item's directory. Temp+rename,
    /// so a reader never sees a half-written file.
    public func write(_ data: Data, to file: String, for id: String) throws(StoreError) {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        try wrap { try data.write(to: fileURL(id, file), options: .atomic) }
    }

    /// Read a content file, or `nil` if it does not exist.
    public func read(file: String, for id: String) throws(StoreError) -> Data? {
        let url = fileURL(id, file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try wrap { try Data(contentsOf: url) }
    }

    /// Whether a content file exists — a cheap presence check used to pinpoint the
    /// resume stage of an `organizing` item (`pass1.txt` present ⇒ resume at pass 2).
    public func hasContent(_ file: String, for id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(id, file).path)
    }

    // MARK: - Transitions

    /// Recording finished: move to `queued` and stamp the recording `duration`.
    public func markQueued(_ id: String, duration: TimeInterval) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .queued, at: now(), duration: duration), for: id)
    }

    /// The transcription lane picked the item up: move to `transcribing`.
    public func markTranscribing(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .transcribing, at: now()), for: id)
    }

    /// Transcription done, organization starting: move to `organizing`.
    public func markOrganizing(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .organizing, at: now()), for: id)
    }

    /// Happy path terminal: write the final pass-2 text, *then* flip to `organized`.
    /// The content is durable before the state that makes it copyable, so the
    /// invariant "final text present only in `organized`" cannot be half-observed.
    public func markOrganized(_ id: String, finalText: String) throws(StoreError) -> ItemMeta {
        let current = try meta(for: id)
        try write(Data(finalText.utf8), to: ItemFile.final, for: id)
        return try persist(current.advancing(to: .organized, at: now()), for: id)
    }

    /// Terminal off-ramp: the item broke at `stage` for `reason`.
    public func fail(
        _ id: String, stage: Stage, reason: FailureReason, detail: String? = nil
    ) throws(StoreError) -> ItemMeta {
        try persist(
            try meta(for: id).failing(stage: stage, reason: reason, detail: detail, at: now()),
            for: id)
    }

    /// Terminal off-ramp: the user stopped the item at `stage`.
    public func cancel(_ id: String, stage: Stage) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).cancelling(stage: stage, at: now()), for: id)
    }

    // MARK: - Retry re-entry

    /// Retry from the transcription stage: move a `failed`/`cancelled` item back to
    /// `queued` so the serial lane re-transcribes it, reusing the retained
    /// `audio.mp3`. Preserves the recording `duration`; clears the error/stoppedAt
    /// (the happy path is being re-entered). No auto-retry — the caller is a click.
    public func requeueForRetry(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .queued, at: now()), for: id)
    }

    /// Retry from an organization stage: move a `failed`/`cancelled` item back to the
    /// `transcribing` handoff state so the parallel lane re-runs the passes, reusing
    /// the retained `transcript.txt` (and `pass1.txt` for a pass-2 resume). The lane's
    /// `transcribing` guard is the handoff contract, so retry re-enters through it
    /// rather than a bespoke state. Clears the error/stoppedAt.
    public func resumeForOrganizing(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .transcribing, at: now()), for: id)
    }

    // MARK: - Read

    /// Load an item's `meta.json`.
    public func meta(for id: String) throws(StoreError) -> ItemMeta {
        let url = fileURL(id, ItemFile.meta)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.itemNotFound(id) }
        let data = try wrap { try Data(contentsOf: url) }
        do {
            return try Self.decoder().decode(ItemMeta.self, from: data)
        } catch {
            throw StoreError.malformedMeta(id: id, detail: "\(error)")
        }
    }

    /// All items, ordered by `created` (id, a ULID, breaks any same-instant tie for
    /// a deterministic total order). Entries without a decodable `meta.json` (junk
    /// directories, half-created dirs) are skipped, never fatal.
    public func list() throws(StoreError) -> [Item] {
        try items().sorted {
            $0.meta.created != $1.meta.created ? $0.meta.created < $1.meta.created : $0.id < $1.id
        }
    }

    /// The final pass-2 text, present only when the item is `organized`. Nothing
    /// partial is ever returned as final (the load-bearing invariant).
    public func finalText(for id: String) throws(StoreError) -> String? {
        guard try meta(for: id).state == .organized else { return nil }
        guard let data = try read(file: ItemFile.final, for: id) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Delete

    /// Delete an item by moving its directory to the macOS Trash (recoverable).
    public func delete(_ id: String) throws(StoreError) {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        try wrap { try FileManager.default.trashItem(at: directory(for: id), resultingItemURL: nil) }
    }

    /// Silently hard-remove an item's directory (not to Trash). For a too-short
    /// accidental tap (story 32) and a `recording`-stage orphan: there is no
    /// artifact worth keeping and it should litter neither the log nor the Trash.
    public func discard(_ id: String) throws(StoreError) {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        try wrap { try FileManager.default.removeItem(at: directory(for: id)) }
    }

    // MARK: - Content-file location

    /// The on-disk URL of a content file inside an existing item's directory, for
    /// callers that must write a large artifact in place (streamed) rather than
    /// through `write(_:to:for:)`, which buffers the whole blob in memory. The
    /// audio encode writes the mp3 here so recording never loads the wav into RAM.
    public func contentURL(of file: String, for id: String) throws(StoreError) -> URL {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        return fileURL(id, file)
    }

    // MARK: - Boot recovery

    /// Recover orphans on boot: on a fresh process nothing is live, so every
    /// non-terminal item is stuck. Mark each `failed`/`interrupted` at the stage it
    /// died in (retryable unless it died at `recording`, which has nothing to
    /// resume). Returns the recovered items.
    public func recoverOrphans() throws(StoreError) -> [Item] {
        var recovered: [Item] = []
        for item in try items() where !item.meta.state.isTerminal {
            let stage = recoveryStage(for: item.meta.state, id: item.id)
            let meta = try fail(item.id, stage: stage, reason: .interrupted, detail: "recovered on boot")
            recovered.append(Item(id: item.id, meta: meta))
        }
        return recovered
    }

    // MARK: - Internals

    private func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func fileURL(_ id: String, _ file: String) -> URL {
        directory(for: id).appendingPathComponent(file, isDirectory: false)
    }

    private func directoryExists(_ id: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory(for: id).path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Which stage a non-terminal state died in, for a recovered orphan. An
    /// `organizing` death is pinpointed from the surviving artifacts so retry
    /// resumes from the right pass (#22): `pass1.txt` on disk means pass 1 finished
    /// and pass 2 was interrupted (resume at `pass2`, reusing the pivot); its absence
    /// means pass 1 itself was interrupted (resume at `pass1`, reusing the transcript).
    private func recoveryStage(for state: ItemState, id: String) -> Stage {
        switch state {
        case .recording: return .recording
        case .queued, .transcribing: return .transcription
        case .organizing: return hasContent(ItemFile.pass1, for: id) ? .pass2 : .pass1
        case .organized, .failed, .cancelled:
            return .recording // unreachable: callers filter terminal states first
        }
    }

    /// Every directory under `root` that holds a decodable `meta.json`, unordered.
    private func items() throws(StoreError) -> [Item] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try wrap {
            try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        }
        var result: [Item] = []
        for entry in entries {
            let id = entry.lastPathComponent
            guard directoryExists(id) else { continue }
            guard let loaded = try? meta(for: id) else { continue }
            result.append(Item(id: id, meta: loaded))
        }
        return result
    }

    @discardableResult
    private func persist(_ meta: ItemMeta, for id: String) throws(StoreError) -> ItemMeta {
        try writeMeta(meta, for: id)
        return meta
    }

    private func writeMeta(_ meta: ItemMeta, for id: String) throws(StoreError) {
        let data: Data
        do {
            data = try Self.encoder().encode(meta)
        } catch {
            throw StoreError.io("encoding meta.json for \(id): \(error)")
        }
        try wrap { try data.write(to: fileURL(id, ItemFile.meta), options: .atomic) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = isoFormatter().date(from: string) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid ISO-8601 date: \(string)"))
            }
            return date
        }
        return decoder
    }

    /// ISO-8601 with fractional seconds, so the per-transition timeline keeps the
    /// millisecond resolution the ULID id already carries (two transitions in the
    /// same second must not collapse to one instant). Built per call because
    /// `ISO8601DateFormatter` is not `Sendable`; `meta.json` holds only a handful
    /// of dates, so the cost is negligible.
    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// Run a Foundation-throwing body, wrapping any error as `StoreError.io`.
private func wrap<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
        return try body()
    } catch let error as StoreError {
        throw error
    } catch {
        throw StoreError.io("\(error)")
    }
}

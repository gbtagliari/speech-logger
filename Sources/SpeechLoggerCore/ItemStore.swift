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
    ///
    /// `mode` defaults to `braindump`, mirroring how an absent `mode` reads off disk —
    /// one rule, both directions: unspecified means braindump.
    public func create(mode: ItemMode = .braindump) throws(StoreError) -> Item {
        let created = now()
        let id = makeID(created)
        let dir = directory(for: id)
        try wrap { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let meta = try persist(ItemMeta.recording(created: created, mode: mode), for: id)
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

    /// Whether a content file exists — a cheap presence check for callers that reason
    /// about which artifacts survived.
    public func hasContent(_ file: String, for id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(id, file).path)
    }

    /// Which pass an `organizing` item should resume from, read off the surviving
    /// artifacts (#22): a retained `pass1.txt` means pass 1 finished and pass 2 was
    /// interrupted (resume at `pass2`, reusing the pivot); its absence means pass 1
    /// itself was interrupted (resume at `pass1`, reusing the transcript). The single
    /// home for this rule — boot recovery and the graceful-quit sweep both use it, so
    /// the item-directory layout stays the store's knowledge alone.
    public func organizingResumeStage(for id: String) -> Stage {
        hasContent(ItemFile.pass1, for: id) ? .pass2 : .pass1
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

    /// Transcription done, organization starting: move to `organizing`. Braindump only —
    /// a dictation has no organization stage and is refused here (#41).
    public func markOrganizing(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .organizing, at: now()), for: id)
    }

    /// Dictation's happy-path terminal: the transcript is the output, so the item rests
    /// at `transcribed` rather than entering organization. Dictation only — a braindump
    /// is refused here, the mirror of `markOrganizing` refusing a dictation (#41).
    public func markTranscribed(_ id: String) throws(StoreError) -> ItemMeta {
        try persist(try meta(for: id).advancing(to: .transcribed, at: now()), for: id)
    }

    /// Braindump's happy path terminal: write the final pass-2 text, *then* flip to
    /// `organized`. The content is durable before the state that makes it copyable, so
    /// the invariant "final text present only in `organized`" cannot be half-observed.
    public func markOrganized(_ id: String, finalText: String) throws(StoreError) -> ItemMeta {
        let next = try meta(for: id).advancing(to: .organized, at: now())
        // Checked before the content write, not just in `persist`: a refused transition
        // must leave no orphan `final.txt` behind for a later read to trip on.
        try requireReachable(next, for: id)
        try write(Data(finalText.utf8), to: ItemFile.final, for: id)
        return try persist(next, for: id)
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

    /// Reprocess from the top: move a settled item back to `queued` and drop every
    /// artifact derived from the audio, so the serial lane re-transcribes and both
    /// passes run again over fresh text (#24). Preserves the recording `duration` and
    /// `audio.mp3` — the input — and clears the error/stoppedAt.
    ///
    /// The derived files go *after* the state flips, mirroring the write order: content
    /// becomes durable before the state that exposes it, so it stops being exposed before
    /// it is removed. `final.txt` does briefly outlive the flip, but it is unreadable as
    /// final the whole time — `finalText(for:)` gates on `state == .organized`. Flipping
    /// first is what makes an interruption mid-sweep survivable: it leaves stale files
    /// under a `queued` item, which the re-run overwrites, instead of an `organized` item
    /// with no text to copy, which nothing recovers.
    ///
    /// Dropping `pass1.txt` is load-bearing, not tidiness: `organizingResumeStage` reads
    /// the resume pass off its presence, so a stale pivot would send a later retry to
    /// pass 2 to rewrite the very text the reprocess was undoing.
    ///
    /// Refused outright for a dictation (#41). `Item.isReprocessable` already hides the
    /// control, but that is a UI predicate and this is the one call that deletes before
    /// it rebuilds: on a dictation it would drop the transcript — the mode's only output
    /// — to re-run passes that never existed. The guard belongs where the destruction is.
    public func requeueForReprocess(_ id: String) throws(StoreError) -> ItemMeta {
        let current = try meta(for: id)
        guard current.mode == .braindump else {
            throw StoreError.reprocessUnavailable(id: id, mode: current.mode)
        }
        let meta = try persist(current.advancing(to: .queued, at: now()), for: id)
        for file in ItemFile.derived { try removeContent(file, for: id) }
        return meta
    }

    /// Delete a content file if it is there. Absence is success: callers clear a stage's
    /// artifacts without first knowing which of them a partial run got as far as writing.
    private func removeContent(_ file: String, for id: String) throws(StoreError) {
        guard hasContent(file, for: id) else { return }
        try wrap { try FileManager.default.removeItem(at: fileURL(id, file)) }
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
    /// accidental tap and a `recording`-stage orphan: there is no artifact worth
    /// keeping and it should litter neither the log nor the Trash.
    public func discard(_ id: String) throws(StoreError) {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        try wrap { try FileManager.default.removeItem(at: directory(for: id)) }
    }

    // MARK: - Content-file location

    /// The on-disk URL of an existing item's own directory, for callers that reveal
    /// it to the user (the panel's "abrir pasta"). Throws rather than returning a
    /// speculative URL, so a caller never opens a path that is not there.
    public func directoryURL(for id: String) throws(StoreError) -> URL {
        guard directoryExists(id) else { throw StoreError.itemNotFound(id) }
        return directory(for: id)
    }

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
    /// `organizing` death is pinpointed from the surviving artifacts (`organizingResumeStage`)
    /// so retry resumes from the right pass (#22).
    private func recoveryStage(for state: ItemState, id: String) -> Stage {
        switch state {
        case .recording: return .recording
        case .queued, .transcribing: return .transcription
        case .organizing: return organizingResumeStage(for: id)
        case .transcribed, .organized, .failed, .cancelled:
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
        try requireReachable(meta, for: id)
        try writeMeta(meta, for: id)
        return meta
    }

    /// Refuse a state the item's mode never reaches (#41). Every transition funnels
    /// through `persist`, so this one guard is what makes "a braindump never rests in
    /// `transcribed`, a dictation never reaches `organizing`" a property of the disk
    /// rather than a convention each caller has to keep.
    private func requireReachable(_ meta: ItemMeta, for id: String) throws(StoreError) {
        guard meta.mode.reaches(meta.state) else {
            throw StoreError.unreachableState(id: id, mode: meta.mode, state: meta.state)
        }
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

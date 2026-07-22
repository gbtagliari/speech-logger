import Foundation

/// The menubar panel as a pure value, built from the item list. Four sections mirror
/// the panel's four headings, so the SwiftUI view is a thin render of this model and
/// the sectioning/ordering/labelling logic stays testable here.
///
/// - *Acontecendo agora* (`live`): the recording clock plus queued / transcribing /
///   organizing, newest first, making the lane model the hero. The **one shared**
///   section: an in-flight dictation is in the same serial lane and shows up here.
/// - *Prontos* (`ready`): organized items, newest first, each with a clamped preview
///   of its final pass-2 text. Braindumps only.
/// - *Precisam de você* (`needsYou`): failed and cancelled items, newest first, with
///   retry offered only where there is something to resume. Braindumps only.
/// - *Ditados* (`dictations`): every dictation that has reached a terminal state,
///   newest first (#44).
///
/// Terminal dictations are kept out of the braindump log deliberately: the log is the
/// record of formed thought, and a mode used dozens of times a day would bury it under
/// throwaway commands. They rejoin it while in flight, where the subject is the lane
/// and not the text.
public struct PanelModel: Equatable, Sendable {
    public let live: [LiveRow]
    public let ready: [ReadyRow]
    public let needsYou: [NeedsRow]
    public let dictations: [DictationRow]

    public init(
        live: [LiveRow], ready: [ReadyRow], needsYou: [NeedsRow],
        dictations: [DictationRow]
    ) {
        self.live = live
        self.ready = ready
        self.needsYou = needsYou
        self.dictations = dictations
    }

    public var isEmpty: Bool {
        live.isEmpty && ready.isEmpty && needsYou.isEmpty && dictations.isEmpty
    }

    /// A row of the live pipeline. `kind` distinguishes the recording clock (red,
    /// with its own live seconds) from the drip-fed lanes (an indeterminate bar).
    public struct LiveRow: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case recording
            /// 1-based FIFO position in the serial transcription lane.
            case queued(position: Int)
            case transcribing
            case organizing
        }

        public let id: String
        public let kind: Kind
        /// The pt-BR stage label ("Gravando", "Na fila · 2º", "Transcrevendo", …).
        public let label: String
    }

    /// A ready (organized) row: the clamped final-text preview and its age.
    public struct ReadyRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let preview: String
        public let timeText: String
    }

    /// A row that needs the user: `failed` (amber, reason) or `cancelled` (grey,
    /// stage). `isRetryable` is false when the death has nothing to resume (a
    /// recording-stage failure), so the view hides retry and offers delete only.
    public struct NeedsRow: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case failed, cancelled }

        public let id: String
        public let kind: Kind
        /// The pt-BR line ("Falhou · sem fala detectada" / "Cancelado na organização").
        public let label: String
        public let isRetryable: Bool
        /// Whether the row offers "Reprocessar" — a full re-run from the audio (#24).
        /// Carried separately from `isRetryable` because the two answer different
        /// questions ("a stage to resume?" vs "audio to run again?"); they happen to
        /// agree on every death, and diverge on `organized`, which is a `ReadyRow` and
        /// so is always reprocessable and never retryable.
        public let isReprocessable: Bool
        public let timeText: String
    }

    /// A dictation that has reached a terminal state (#44). One row shape for all three
    /// terminals, because the section is a single list the user scans for the text they
    /// just spoke: a finished one reads as its transcript, a dead one as how it died.
    ///
    /// There is no `isReprocessable`: reprocess exists to start the LLM run over and the
    /// mode has no LLM run, so the control is absent from the type rather than carried
    /// as a flag that is always false.
    public struct DictationRow: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case done, failed, cancelled }

        public let id: String
        public let kind: Kind
        /// The clamped transcript for a finished dictation; the pt-BR death line
        /// ("Falhou · saída vazia") for a dead one.
        public let label: String
        /// Whether clicking the row copies its text — true only for a finished one,
        /// which is the only kind that has any.
        public let isCopyable: Bool
        /// Whether retry is offered. On a dictation it can only ever mean *re-transcribe*
        /// the retained audio, and as everywhere else it is offered on a death with a
        /// stage to resume, never on the happy path.
        public let isRetryable: Bool
        public let timeText: String
    }

    /// Build the model from the current items.
    ///
    /// - Parameters:
    ///   - items: every log item (any order; sectioning and ordering happen here).
    ///   - now: the reference instant for the relative-time stamps.
    ///   - outputText: the item's copyable output, looked up by id — the final pass-2
    ///     text for a braindump, the raw transcript for a dictation. Kept a closure so
    ///     the pure builder never touches the store; the app injects a
    ///     `store.outputText(for:)` read and tests inject a stub.
    public static func build(
        items: [Item],
        now: Date,
        outputText: (String) -> String?
    ) -> PanelModel {
        // FIFO order matches the serial transcription lane's arrival order, so the
        // oldest queued item is 1º in line.
        let queued = items
            .filter { $0.state == .queued }
            .sorted { sortKey($0) < sortKey($1) }
        let position = Dictionary(
            uniqueKeysWithValues: queued.enumerated().map { ($0.element.id, $0.offset + 1) })

        // `liveRow` returns nil for terminal states, so "liveness" is defined in one
        // place and the compactMap drops non-live items without a second predicate.
        let live = items
            .sorted { sortKey($0) > sortKey($1) }
            .compactMap { liveRow($0, position: position[$0.id]) }

        let ready = items
            .filter { $0.state == .organized }
            .sorted { sortKey($0) > sortKey($1) }
            .map { item in
                ReadyRow(
                    id: item.id,
                    preview: ReadyPreview.clamp(outputText(item.id) ?? ""),
                    timeText: CompactRelativeTime.text(from: item.meta.created, now: now))
            }

        // *Precisam de você* excludes dictations by mode, since both off-ramps are
        // shared. *Prontos* needs no such filter: `organized` is a state a dictation
        // cannot reach at all (`ItemMode.reaches`), so the state test is already the
        // mode test. The dictation section takes every terminal dictation, whichever of
        // the three terminals it reached.
        let needsYou = items
            .filter { $0.meta.mode == .braindump }
            .filter { $0.state == .failed || $0.state == .cancelled }
            .sorted { sortKey($0) > sortKey($1) }
            .map { needsRow($0, now: now) }

        let dictations = items
            .filter { $0.meta.mode == .dictation && $0.state.isTerminal }
            .sorted { sortKey($0) > sortKey($1) }
            .map { dictationRow($0, now: now, outputText: outputText) }

        return PanelModel(live: live, ready: ready, needsYou: needsYou, dictations: dictations)
    }

    // MARK: - Row construction

    /// The live row for a pipeline state, or nil for a terminal state (which belongs
    /// to *Prontos* or *Precisam de você*, not the live section).
    private static func liveRow(_ item: Item, position: Int?) -> LiveRow? {
        switch item.state {
        case .recording:
            return LiveRow(id: item.id, kind: .recording, label: "Gravando")
        case .queued:
            let pos = position ?? 1
            return LiveRow(id: item.id, kind: .queued(position: pos), label: "Na fila · \(pos)º")
        case .transcribing:
            return LiveRow(id: item.id, kind: .transcribing, label: "Transcrevendo")
        case .organizing:
            return LiveRow(id: item.id, kind: .organizing, label: "Organizando")
        case .transcribed, .organized, .failed, .cancelled:
            return nil
        }
    }

    private static func needsRow(_ item: Item, now: Date) -> NeedsRow {
        NeedsRow(
            id: item.id,
            kind: item.state == .cancelled ? .cancelled : .failed,
            label: deathLabel(item),
            isRetryable: item.isRetryable, isReprocessable: item.isReprocessable,
            timeText: CompactRelativeTime.text(from: item.meta.created, now: now))
    }

    /// The row for a terminal dictation: its transcript if it finished, otherwise the
    /// death line — literally the same one the braindump log shows, since both sections
    /// call `deathLabel`, so a failure reads identically wherever it is found (#44).
    private static func dictationRow(
        _ item: Item, now: Date, outputText: (String) -> String?
    ) -> DictationRow {
        let timeText = CompactRelativeTime.text(from: item.meta.created, now: now)
        switch item.state {
        case .transcribed:
            // Retry is never offered here, for the same reason it is never offered on an
            // organized braindump: nothing died, so there is no stage to resume. A clean
            // dictation that came out wrong is re-spoken, which is two seconds' work.
            return DictationRow(
                id: item.id, kind: .done,
                label: ReadyPreview.clamp(outputText(item.id) ?? ""),
                isCopyable: true, isRetryable: false, timeText: timeText)
        case .cancelled:
            return DictationRow(
                id: item.id, kind: .cancelled, label: deathLabel(item),
                isCopyable: false, isRetryable: item.isRetryable, timeText: timeText)
        case .failed, .recording, .queued, .transcribing, .organizing, .organized:
            // Only `failed` actually arrives: callers pass terminal dictations, and a
            // dictation reaches neither `organizing` nor `organized`. Enumerated rather
            // than defaulted so a new state cannot quietly render as a failure.
            return DictationRow(
                id: item.id, kind: .failed, label: deathLabel(item),
                isCopyable: false, isRetryable: item.isRetryable, timeText: timeText)
        }
    }

    /// The pt-BR line for a dead item, shared by *Precisam de você* and the dictation
    /// list: a cancellation names where the user stopped it, a failure names why it
    /// broke. One home, so the two sections cannot drift apart.
    private static func deathLabel(_ item: Item) -> String {
        item.state == .cancelled
            ? "Cancelado na \(stageLabel(item.meta.stoppedAt?.stage))"
            : "Falhou · \(reasonLabel(item.meta.error?.reason))"
    }

    // MARK: - pt-BR labels

    private static func reasonLabel(_ reason: FailureReason?) -> String {
        switch reason {
        case .emptyOutput: return "saída vazia"
        case .cliError: return "erro no processamento"
        case .missingBinary: return "dependência ausente"
        case .interrupted: return "interrompido"
        case .timeout: return "tempo esgotado"
        case nil: return "erro desconhecido"
        }
    }

    private static func stageLabel(_ stage: Stage?) -> String {
        switch stage {
        case .recording: return "gravação"
        case .transcription: return "transcrição"
        case .pass1, .pass2: return "organização"
        case nil: return "processamento"
        }
    }

    // MARK: - Ordering

    /// The total-order key: by creation time, with the ULID id breaking a same-instant
    /// tie. Compared with `>` for newest-first (the display order) and `<` for FIFO
    /// (the transcription lane's arrival order).
    private static func sortKey(_ item: Item) -> (Date, String) {
        (item.meta.created, item.id)
    }
}

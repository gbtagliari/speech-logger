import Foundation

/// The menubar panel as a pure value, built from the item list. Three sections mirror
/// the panel's three headings, so the SwiftUI view is a thin render of this model and
/// the sectioning/ordering/labelling logic stays testable here.
///
/// - *Acontecendo agora* (`live`): the recording clock plus queued / transcribing /
///   organizing, newest first, making the lane model the hero.
/// - *Prontos* (`ready`): organized items, newest first, each with a clamped preview
///   of its final pass-2 text.
/// - *Precisam de você* (`needsYou`): failed and cancelled items, newest first, with
///   retry offered only where there is something to resume.
public struct PanelModel: Equatable, Sendable {
    public let live: [LiveRow]
    public let ready: [ReadyRow]
    public let needsYou: [NeedsRow]

    public init(live: [LiveRow], ready: [ReadyRow], needsYou: [NeedsRow]) {
        self.live = live
        self.ready = ready
        self.needsYou = needsYou
    }

    public var isEmpty: Bool { live.isEmpty && ready.isEmpty && needsYou.isEmpty }

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

    /// Build the model from the current items.
    ///
    /// - Parameters:
    ///   - items: every log item (any order; sectioning and ordering happen here).
    ///   - now: the reference instant for the relative-time stamps.
    ///   - finalText: the organized item's final pass-2 text, looked up by id. Kept a
    ///     closure so the pure builder never touches the store; the app injects a
    ///     `store.finalText(for:)` read and tests inject a stub.
    public static func build(
        items: [Item],
        now: Date,
        finalText: (String) -> String?
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
                    preview: ReadyPreview.clamp(finalText(item.id) ?? ""),
                    timeText: CompactRelativeTime.text(from: item.meta.created, now: now))
            }

        let needsYou = items
            .filter { $0.state == .failed || $0.state == .cancelled }
            .sorted { sortKey($0) > sortKey($1) }
            .map { needsRow($0, now: now) }

        return PanelModel(live: live, ready: ready, needsYou: needsYou)
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
        let timeText = CompactRelativeTime.text(from: item.meta.created, now: now)
        switch item.state {
        case .cancelled:
            let stage = item.meta.stoppedAt?.stage
            return NeedsRow(
                id: item.id, kind: .cancelled,
                label: "Cancelado na \(stageLabel(stage))",
                isRetryable: item.isRetryable, isReprocessable: item.isReprocessable,
                timeText: timeText)
        default:  // .failed (callers pass only failed/cancelled)
            let reason = item.meta.error?.reason
            return NeedsRow(
                id: item.id, kind: .failed,
                label: "Falhou · \(reasonLabel(reason))",
                isRetryable: item.isRetryable, isReprocessable: item.isReprocessable,
                timeText: timeText)
        }
    }

    // MARK: - pt-BR labels

    private static func reasonLabel(_ reason: FailureReason?) -> String {
        switch reason {
        case .noSpeech: return "sem fala detectada"
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

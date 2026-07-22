import Foundation
import Testing

@testable import SpeechLoggerCore

/// The panel is four sections built purely from the item list:
/// *Acontecendo agora* (recording + queued/transcribing/organizing, both modes),
/// *Prontos* (organized, clamped preview, newest first), *Precisam de você* (failed +
/// cancelled, with retry only where there is something to resume), and *Ditados* (every
/// settled dictation, kept out of the braindump log — #44).
struct PanelModelTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// An item at `id`/`created` in a given state, with the error/stoppedAt a failed
    /// or cancelled item needs to be (non-)retryable.
    private func item(
        _ id: String, created: Date, state: ItemState, mode: ItemMode = .braindump,
        failedStage: Stage? = nil, reason: FailureReason = .cliError, cancelledStage: Stage? = nil
    ) -> Item {
        var meta = ItemMeta(state: state, mode: mode, created: created)
        if state == .failed, let stage = failedStage {
            meta = ItemMeta.recording(created: created, mode: mode)
                .failing(stage: stage, reason: reason, detail: nil, at: created)
        }
        if state == .cancelled, let stage = cancelledStage {
            meta = ItemMeta.recording(created: created, mode: mode)
                .cancelling(stage: stage, at: created)
        }
        return Item(id: id, meta: meta)
    }

    private func noText(_: String) -> String? { nil }

    @Test("each state lands in its section")
    func sectionsSplitByState() {
        let items = [
            item("rec", created: base, state: .recording),
            item("q", created: base, state: .queued),
            item("t", created: base, state: .transcribing),
            item("o", created: base, state: .organizing),
            item("done", created: base, state: .organized),
            item("f", created: base, state: .failed, failedStage: .pass1),
            item("c", created: base, state: .cancelled, cancelledStage: .pass2),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(Set(model.live.map(\.id)) == ["rec", "q", "t", "o"])
        #expect(model.ready.map(\.id) == ["done"])
        #expect(Set(model.needsYou.map(\.id)) == ["f", "c"])
    }

    @Test("live rows are newest first, and recording carries the recording kind")
    func liveNewestFirst() {
        let items = [
            item("old", created: base, state: .transcribing),
            item("new", created: base.addingTimeInterval(10), state: .recording),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(model.live.map(\.id) == ["new", "old"])
        #expect(model.live.first?.kind == .recording)
        #expect(model.live.first?.label == "Gravando")
    }

    @Test("queued items get a 1-based FIFO position, oldest first in line")
    func queuePositions() {
        let items = [
            item("second", created: base.addingTimeInterval(5), state: .queued),
            item("first", created: base, state: .queued),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let first = model.live.first { $0.id == "first" }
        let second = model.live.first { $0.id == "second" }
        #expect(first?.kind == .queued(position: 1))
        #expect(first?.label == "Na fila · 1º")
        #expect(second?.kind == .queued(position: 2))
        #expect(second?.label == "Na fila · 2º")
    }

    @Test("transcribing and organizing carry their pt-BR labels")
    func inflightLabels() {
        let items = [
            item("t", created: base, state: .transcribing),
            item("o", created: base.addingTimeInterval(1), state: .organizing),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(model.live.first { $0.id == "t" }?.label == "Transcrevendo")
        #expect(model.live.first { $0.id == "o" }?.label == "Organizando")
    }

    @Test("ready rows are newest first with a clamped preview and a time stamp")
    func readyRows() {
        let items = [
            item("older", created: base, state: .organized),
            item("newer", created: base.addingTimeInterval(3600), state: .organized),
        ]
        let text: (String) -> String? = { id in
            id == "newer" ? "texto novo" : String(repeating: "a", count: 500)
        }
        let model = PanelModel.build(items: items, now: base.addingTimeInterval(7200), outputText: text)
        #expect(model.ready.map(\.id) == ["newer", "older"])
        #expect(model.ready.first?.preview == "texto novo")
        #expect(model.ready.first?.timeText == "1 h")
        // The long one is clamped.
        #expect(model.ready.last?.preview.hasSuffix("…") == true)
        #expect(model.ready.last?.timeText == "2 h")
    }

    @Test("a failed item shows the reason and, off the recording stage, is retryable")
    func failedRetryable() {
        let items = [item("f", created: base, state: .failed, failedStage: .pass1, reason: .cliError)]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.kind == .failed)
        #expect(row.label == "Falhou · erro no processamento")
        #expect(row.isRetryable)
    }

    @Test("a failure at the recording stage is not retryable: no audio survived it")
    func recordingFailureNotRetryable() {
        // The only recording-stage failure left is a broken encode. `no_speech` is
        // gone (#46): a recording with no speech in it is discarded, never failed.
        let items = [
            item("f", created: base, state: .failed, failedStage: .recording, reason: .cliError)
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.label == "Falhou · erro no processamento")
        #expect(!row.isRetryable)
    }

    @Test("a cancelled item shows the stage it stopped at and is retryable off recording")
    func cancelledRow() {
        let items = [item("c", created: base, state: .cancelled, cancelledStage: .transcription)]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.kind == .cancelled)
        #expect(row.label == "Cancelado na transcrição")
        #expect(row.isRetryable)
    }

    @Test("a death off the recording stage offers reprocess: its audio survived (#24)")
    func needsRowReprocessable() {
        let items = [item("f", created: base, state: .failed, failedStage: .pass2, reason: .cliError)]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(try! #require(model.needsYou.first).isReprocessable)
    }

    @Test("a recording-stage death offers neither retry nor reprocess: there is no audio")
    func recordingDeathOffersNothing() {
        let items = [
            item("f", created: base, state: .failed, failedStage: .recording, reason: .cliError)
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(!row.isRetryable)
        #expect(!row.isReprocessable)
    }

    @Test("needs-you rows are newest first")
    func needsYouNewestFirst() {
        let items = [
            item("old", created: base, state: .failed, failedStage: .pass1),
            item("new", created: base.addingTimeInterval(10), state: .cancelled, cancelledStage: .pass2),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(model.needsYou.map(\.id) == ["new", "old"])
    }

    @Test("an empty list yields an empty model")
    func emptyModel() {
        let model = PanelModel.build(items: [], now: base, outputText: noText)
        #expect(model.isEmpty)
    }

    // MARK: - The dictation list (#44)

    @Test("settled dictations get their own section, out of Prontos and Precisam de você")
    func dictationsKeptOutOfTheBraindumpLog() {
        let items = [
            item("d-done", created: base, state: .transcribed, mode: .dictation),
            item("d-failed", created: base, state: .failed, mode: .dictation,
                failedStage: .transcription),
            item("d-cancelled", created: base, state: .cancelled, mode: .dictation,
                cancelledStage: .transcription),
            item("b-done", created: base, state: .organized),
            item("b-failed", created: base, state: .failed, failedStage: .pass1),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(Set(model.dictations.map(\.id)) == ["d-done", "d-failed", "d-cancelled"])
        #expect(model.ready.map(\.id) == ["b-done"])
        #expect(model.needsYou.map(\.id) == ["b-failed"])
    }

    @Test("an in-flight dictation shares Acontecendo agora with the braindumps")
    func inFlightDictationIsLive() {
        let items = [
            item("d", created: base.addingTimeInterval(10), state: .transcribing, mode: .dictation),
            item("b", created: base, state: .queued),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(model.live.map(\.id) == ["d", "b"])
        // It is not in the dictation list yet: that section is the record of settled ones.
        #expect(model.dictations.isEmpty)
    }

    @Test("a finished dictation shows its transcript, copyable, with no death to retry")
    func doneDictationRow() {
        let items = [item("d", created: base, state: .transcribed, mode: .dictation)]
        let text: (String) -> String? = { _ in "manda o print pro canal" }
        let model = PanelModel.build(
            items: items, now: base.addingTimeInterval(3600), outputText: text)
        let row = try! #require(model.dictations.first)
        #expect(row.kind == .done)
        #expect(row.label == "manda o print pro canal")
        #expect(row.isCopyable)
        #expect(!row.isRetryable)
        #expect(row.timeText == "1 h")
    }

    @Test("a long dictation is clamped like a ready preview")
    func doneDictationClamped() {
        let items = [item("d", created: base, state: .transcribed, mode: .dictation)]
        let text: (String) -> String? = { _ in String(repeating: "a", count: 500) }
        let model = PanelModel.build(items: items, now: base, outputText: text)
        #expect(try! #require(model.dictations.first).label.hasSuffix("…"))
    }

    @Test("a dead dictation reads its death and offers retry, which re-transcribes")
    func deadDictationRow() {
        let items = [
            item("f", created: base, state: .failed, mode: .dictation,
                failedStage: .transcription, reason: .emptyOutput),
            item("c", created: base.addingTimeInterval(1), state: .cancelled, mode: .dictation,
                cancelledStage: .transcription),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        let failed = try! #require(model.dictations.first { $0.id == "f" })
        #expect(failed.kind == .failed)
        #expect(failed.label == "Falhou · saída vazia")
        #expect(failed.isRetryable)
        #expect(!failed.isCopyable)

        let cancelled = try! #require(model.dictations.first { $0.id == "c" })
        #expect(cancelled.kind == .cancelled)
        #expect(cancelled.label == "Cancelado na transcrição")
        #expect(cancelled.isRetryable)
    }

    @Test("a dictation that died at the recording stage has nothing to retry")
    func recordingDeathDictation() {
        let items = [
            item("d", created: base, state: .failed, mode: .dictation, failedStage: .recording)
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(!(try! #require(model.dictations.first).isRetryable))
    }

    @Test("dictation rows are newest first")
    func dictationsNewestFirst() {
        let items = [
            item("old", created: base, state: .transcribed, mode: .dictation),
            item("new", created: base.addingTimeInterval(10), state: .transcribed, mode: .dictation),
        ]
        let model = PanelModel.build(items: items, now: base, outputText: noText)
        #expect(model.dictations.map(\.id) == ["new", "old"])
    }

    @Test("a model holding only dictations is not empty")
    func dictationsCountTowardEmptiness() {
        let items = [item("d", created: base, state: .transcribed, mode: .dictation)]
        #expect(!PanelModel.build(items: items, now: base, outputText: noText).isEmpty)
    }
}

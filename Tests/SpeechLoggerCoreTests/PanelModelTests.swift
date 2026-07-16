import Foundation
import Testing

@testable import SpeechLoggerCore

/// The panel is three sections built purely from the item list (SPEC "UI"):
/// *Acontecendo agora* (recording + queued/transcribing/organizing), *Prontos*
/// (organized, clamped preview, newest first), *Precisam de você* (failed +
/// cancelled, with retry only where there is something to resume).
struct PanelModelTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// An item at `id`/`created` in a given state, with the error/stoppedAt a failed
    /// or cancelled item needs to be (non-)retryable.
    private func item(
        _ id: String, created: Date, state: ItemState,
        failedStage: Stage? = nil, reason: FailureReason = .cliError, cancelledStage: Stage? = nil
    ) -> Item {
        var meta = ItemMeta(state: state, created: created)
        if state == .failed, let stage = failedStage {
            meta = ItemMeta.recording(created: created)
                .failing(stage: stage, reason: reason, detail: nil, at: created)
        }
        if state == .cancelled, let stage = cancelledStage {
            meta = ItemMeta.recording(created: created).cancelling(stage: stage, at: created)
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
        let model = PanelModel.build(items: items, now: base, finalText: noText)
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
        let model = PanelModel.build(items: items, now: base, finalText: noText)
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
        let model = PanelModel.build(items: items, now: base, finalText: noText)
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
        let model = PanelModel.build(items: items, now: base, finalText: noText)
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
        let model = PanelModel.build(items: items, now: base.addingTimeInterval(7200), finalText: text)
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
        let model = PanelModel.build(items: items, now: base, finalText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.kind == .failed)
        #expect(row.label == "Falhou · erro no processamento")
        #expect(row.isRetryable)
    }

    @Test("a no_speech failure at the recording stage is not retryable")
    func noSpeechNotRetryable() {
        let items = [
            item("f", created: base, state: .failed, failedStage: .recording, reason: .noSpeech)
        ]
        let model = PanelModel.build(items: items, now: base, finalText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.label == "Falhou · sem fala detectada")
        #expect(!row.isRetryable)
    }

    @Test("a cancelled item shows the stage it stopped at and is retryable off recording")
    func cancelledRow() {
        let items = [item("c", created: base, state: .cancelled, cancelledStage: .transcription)]
        let model = PanelModel.build(items: items, now: base, finalText: noText)
        let row = try! #require(model.needsYou.first)
        #expect(row.kind == .cancelled)
        #expect(row.label == "Cancelado na transcrição")
        #expect(row.isRetryable)
    }

    @Test("needs-you rows are newest first")
    func needsYouNewestFirst() {
        let items = [
            item("old", created: base, state: .failed, failedStage: .pass1),
            item("new", created: base.addingTimeInterval(10), state: .cancelled, cancelledStage: .pass2),
        ]
        let model = PanelModel.build(items: items, now: base, finalText: noText)
        #expect(model.needsYou.map(\.id) == ["new", "old"])
    }

    @Test("an empty list yields an empty model")
    func emptyModel() {
        let model = PanelModel.build(items: [], now: base, finalText: noText)
        #expect(model.isEmpty)
    }
}

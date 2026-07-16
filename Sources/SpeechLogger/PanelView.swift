import SpeechLoggerCore
import SwiftUI

/// The menubar dropdown panel (SPEC "UI"): three sections built from `PanelModel`,
/// plus the degraded Input-Monitoring banner and a footer. A thin render of
/// `PanelViewModel` — no pipeline logic lives here.
struct PanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    /// The id whose "copiado" flash is showing, cleared shortly after a copy.
    @State private var copiedID: String?

    private let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: width)
        .font(.system(size: 12.5))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("speech logger").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.needsPermission { permissionBanner }
                if viewModel.model.isEmpty && !viewModel.needsPermission {
                    emptyState
                } else {
                    liveSection
                    readySection
                    needsYouSection
                }
            }
        }
        .frame(maxHeight: 432)
    }

    @ViewBuilder private var liveSection: some View {
        if !viewModel.model.live.isEmpty {
            SectionLabel(title: "Acontecendo agora", count: viewModel.model.live.count)
            ForEach(viewModel.model.live) { row in
                LiveRowView(
                    row: row,
                    recordingSeconds: viewModel.recordingSeconds,
                    onStop: { viewModel.onStop(row.id) })
            }
        }
    }

    @ViewBuilder private var readySection: some View {
        if !viewModel.model.ready.isEmpty {
            SectionLabel(title: "Prontos", count: viewModel.model.ready.count)
            ForEach(viewModel.model.ready) { row in
                ReadyRowView(
                    row: row,
                    justCopied: copiedID == row.id,
                    onCopy: { copy(row.id) },
                    onDelete: { viewModel.onDelete(row.id) })
            }
        }
    }

    @ViewBuilder private var needsYouSection: some View {
        if !viewModel.model.needsYou.isEmpty {
            SectionLabel(title: "Precisam de você", count: viewModel.model.needsYou.count)
            ForEach(viewModel.model.needsYou) { row in
                NeedsRowView(
                    row: row,
                    onRetry: { viewModel.onRetry(row.id) },
                    onDelete: { viewModel.onDelete(row.id) })
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Monitoramento de Entrada desativado", systemImage: "exclamationmark.lock")
                .foregroundStyle(.orange).font(.system(size: 12, weight: .medium))
            Text("O atalho fica surdo até você permitir.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Abrir Ajustes do Sistema…") { viewModel.onOpenSettings() }
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var emptyState: some View {
        Text("Nada por aqui ainda. Aperte ⌥⌥ e fale.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footnote).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("Sair") { viewModel.onQuit() }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
            Text("⌥⌥").font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
    }

    // A neutral hint: the ready notification is a later ticket, so the footer must
    // not promise it here.
    private let footnote = "clique num item pronto pra copiar"

    // MARK: - Copy feedback

    private func copy(_ id: String) {
        viewModel.onCopy(id)
        copiedID = id
        Task {
            try? await Task.sleep(for: .seconds(1))
            if copiedID == id { copiedID = nil }
        }
    }
}

// MARK: - Section label

private struct SectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(0.6)
            Text("· \(count)").font(.system(size: 10.5, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 4)
    }
}

// MARK: - Live row

private struct LiveRowView: View {
    let row: PanelModel.LiveRow
    let recordingSeconds: Int
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            glyph.frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(labelColor)
                progressBar
            }
            trailing
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// The recording clock (recording is stopped by the hotkey, so it carries no stop
    /// control); every other live kind is a processing item with a hover-revealed
    /// "stop processing" button (story 30).
    @ViewBuilder private var trailing: some View {
        if case .recording = row.kind {
            Text(clock).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.red)
        } else if hovering {
            IconButton(systemName: "stop.fill", help: "parar", action: onStop)
        }
    }

    private var label: String { row.label }

    private var labelColor: Color {
        if case .recording = row.kind { return .red }
        return .primary
    }

    @ViewBuilder private var glyph: some View {
        switch row.kind {
        case .recording: PulsingDot(color: .red)
        case .queued: Circle().strokeBorder(Color.secondary, lineWidth: 1.6).frame(width: 11, height: 11)
        case .transcribing, .organizing:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        }
    }

    @ViewBuilder private var progressBar: some View {
        switch row.kind {
        case .recording:
            Capsule().fill(Color.red).frame(height: 4)
        case .queued:
            // A static track, not an animated bar: a queued item is waiting in line,
            // not working, so it must not animate as if it were.
            Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
        case .transcribing, .organizing:
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        }
    }

    private var clock: String {
        String(format: "%d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }
}

// MARK: - Ready row

private struct ReadyRowView: View {
    let row: PanelModel.ReadyRow
    let justCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(Color.green).frame(width: 8, height: 8).padding(.top, 3)
                Text(row.preview)
                    .font(.system(size: 12.5)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailing: some View {
        if justCopied {
            Text("copiado").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
        } else if hovering {
            IconButton(systemName: "xmark", help: "apagar", action: onDelete)
        } else {
            Text(row.timeText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Needs-you row

private struct NeedsRowView: View {
    let row: PanelModel.NeedsRow
    let onRetry: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: glyphName).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                .frame(width: 16)
            Text(row.label).font(.system(size: 12.5)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailing: some View {
        if hovering {
            HStack(spacing: 4) {
                if row.isRetryable {
                    IconButton(systemName: "arrow.clockwise", help: retryHelp, action: onRetry)
                }
                IconButton(systemName: "xmark", help: "apagar", action: onDelete)
            }
        } else {
            Text(row.timeText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var glyphName: String {
        row.kind == .failed ? "exclamationmark.triangle.fill" : "slash.circle"
    }

    private var tint: Color { row.kind == .failed ? .orange : .secondary }

    private var retryHelp: String { row.kind == .failed ? "tentar de novo" : "retomar" }
}

// MARK: - Shared bits

/// A small pulsing dot for the live recording glyph.
private struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// A borderless icon button used for the hover-revealed row actions.
private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
}

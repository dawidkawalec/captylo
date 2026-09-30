import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Transkrypcja pliku": glass drop zone with a dashed luminous rim, "Wybierz pliki" and the queue
/// rows with a status chip, a thin progress track and copy / retry / remove buttons.
@MainActor
struct TranscribeFileView: View {
    @Environment(AppState.self) private var appState
    @Environment(FileTranscriptionQueue.self) private var queue

    @State private var isTargeted = false

    /// Inset of the drop zone in its panel; the dashed rim radius is concentric with the panel.
    private static let panelInset: CGFloat = 14
    private static let dropZoneRadius: CGFloat = GlassTokens.Radius.panel - panelInset
    /// Alone on the page the drop zone fills most of the window; with a queue it steps back.
    private static let dropZoneHeight: CGFloat = 400
    private static let dropZoneHeightWithQueue: CGFloat = 240

    var body: some View {
        // No subtitle: the drop zone says the same thing, and says it on glass.
        ToolPage {
            GlassPanel(padding: Self.panelInset) {
                dropZone
                if !queue.rejectedNames.isEmpty {
                    ToolStatusLine(
                        text: String(localized: "Pominięto nieobsługiwane pliki: \(queue.rejectedNames.joined(separator: ", "))"),
                        tone: .error
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            if !queue.items.isEmpty {
                queuePanel
            }
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: Self.dropZoneRadius, style: .continuous)
        return VStack(spacing: 14) {
            GlassIconBadge(systemImage: "arrow.down.doc", size: 60, tint: isTargeted ? GlassColor.accent : nil)
                .shadow(color: GlassColor.accent.opacity(isTargeted ? 0.6 : 0.25), radius: 18)
                .scaleEffect(isTargeted ? 1.06 : 1)
            VStack(spacing: 6) {
                Text("Upuść tutaj pliki audio lub wideo")
                    .font(GlassFont.display(18))
                    .foregroundStyle(GlassColor.textPrimary)
                Text(verbatim: "wav, mp3, m4a, aiff, aac, flac, caf, mp4, mov")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .glassTextShadow()
                if queue.items.isEmpty {
                    Text("Gotowe transkrypcje trafiają do Historii.")
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                }
            }
            Button {
                chooseFiles()
            } label: {
                Label("Wybierz pliki", systemImage: "folder")
            }
            .buttonStyle(.glass(.accent, shape: .capsule))
            .keyboardShortcut("o", modifiers: .command)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: queue.items.isEmpty ? Self.dropZoneHeight : Self.dropZoneHeightWithQueue)
        .padding(20)
        .background {
            shape.fill(Color.white.opacity(isTargeted ? 0.10 : 0.03))
                .overlay { shape.fill(GlassColor.accent.opacity(isTargeted ? 0.18 : 0)) }
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(isTargeted ? 0.9 : 0.55), Color.white.opacity(isTargeted ? 0.6 : 0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, lineCap: .round, dash: [7, 7])
            )
            .shadow(color: Color.white.opacity(isTargeted ? 0.45 : 0.18), radius: 6)
        }
        .animation(GlassMotion.spring, value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls: urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Strefa upuszczania plików"))
    }

    // MARK: Queue

    private var queuePanel: some View {
        GlassPanel {
            GlassSectionHeader("Kolejka", systemImage: "list.bullet") {
                GlassBadge(title: Text(verbatim: "\(queue.items.count)"))
            }
            VStack(spacing: 0) {
                ForEach(queue.items) { item in
                    QueueRow(
                        item: item,
                        onCopy: { appState.textOutput.copy($0) },
                        onRetry: { queue.retry(id: item.id) },
                        onRemove: { queue.remove(id: item.id) },
                        onCancel: { queue.cancel(id: item.id) }
                    )
                    if item.id != queue.items.last?.id {
                        GlassRowSeparator(inset: 50)
                    }
                }
            }
            GlassRowSeparator()
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(GlassColor.textTertiary)
                    .accessibilityHidden(true)
                Text("Gotowe transkrypcje trafiają do Historii.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                Spacer()
                Button("Wyczyść zakończone") {
                    queue.clearFinished()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(!queue.hasFinishedItems)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = String(localized: "Wybierz pliki audio lub wideo do transkrypcji")
        panel.prompt = String(localized: "Transkrybuj")
        Task {
            guard await panel.begin() == .OK else { return }
            queue.add(urls: panel.urls)
        }
    }
}

// MARK: - Row

@MainActor
private struct QueueRow: View {
    let item: FileTranscriptionQueue.Item
    let onCopy: (String) -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassIconBadge(systemImage: fileSymbol, size: 36, tint: badgeTint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(verbatim: item.name)
                        .font(GlassFont.ui(14, .medium))
                        .foregroundStyle(GlassColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statusChip
                }
                if let detail {
                    Text(verbatim: detail)
                        .font(GlassFont.caption)
                        .foregroundStyle(isFailed ? GlassColor.destructive : GlassColor.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.status.isActive {
                    ToolProgressTrack(value: nil, height: 4)
                        .padding(.top, 2)
                }
            }
            HStack(spacing: 6) {
                if let text = item.status.text {
                    ToolIconButton("doc.on.doc", label: Text("Kopiuj tekst")) {
                        onCopy(text)
                    }
                }
                if isFailed {
                    ToolIconButton("arrow.clockwise", label: Text("Spróbuj ponownie"), action: onRetry)
                }
                if item.status.isActive {
                    ToolIconButton("xmark", label: Text("Anuluj"), action: onCancel)
                } else {
                    ToolIconButton("xmark", label: Text("Usuń z kolejki"), action: onRemove)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .animation(GlassMotion.spring, value: item.status)
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var fileSymbol: String {
        let type = UTType(filenameExtension: item.url.pathExtension.lowercased())
        return type?.conforms(to: .movie) == true ? "film" : "waveform"
    }

    private var badgeTint: Color? {
        switch item.status {
        case .done: return GlassColor.success
        case .failed: return GlassColor.destructive
        case .decoding, .transcribing, .enhancing: return GlassColor.accent
        case .waiting: return nil
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch item.status {
        case .waiting:
            GlassBadge("Oczekuje", systemImage: "clock")
        case .decoding:
            GlassBadge("Odczytuję plik...", tone: .accent)
        case .transcribing:
            GlassBadge("Transkrybuję...", tone: .accent)
        case .enhancing:
            GlassBadge("Poprawiam z AI...", systemImage: "sparkles", tone: .accent)
        case .done:
            GlassBadge("Gotowe", systemImage: "checkmark", tone: .success)
        case .failed:
            GlassBadge("Błąd", systemImage: "exclamationmark", tone: .danger)
        }
    }

    /// The transcript preview or the error; waiting and active items say it with the chip.
    private var detail: String? {
        switch item.status {
        case .done(let text): return text
        case .failed(let message): return message
        case .waiting, .decoding, .transcribing, .enhancing: return nil
        }
    }
}

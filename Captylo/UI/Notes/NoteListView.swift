import SwiftUI

/// The notes of Notatki, newest first (or best match first while searching), on one glass panel
/// with hairlines between the rows, like the meeting list: the title (or the first line), the
/// date, the length of a recording and a waveform glyph for voice notes. A click or the arrow
/// keys select.
@MainActor
struct NoteListView: View {
    fileprivate static let listPadding: CGFloat = 6

    let notes: [NoteRecord]
    @Binding var selection: UUID?

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassPanel(padding: 0, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 {
                                GlassRowSeparator()
                                    .padding(.horizontal, 14)
                            }
                            NoteListRow(note: note, isSelected: selection == note.id) {
                                isFocused = true
                                selection = note.id
                            }
                            .id(note.id)
                        }
                    }
                    .padding(Self.listPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .clipShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.panel, style: .continuous))
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    move(by: press.key == .upArrow ? -1 : 1, proxy: proxy)
                    return .handled
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Notatki"))
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) {
        guard !notes.isEmpty else { return }
        let ids = notes.map(\.id)
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0
        selection = ids[next]
        if reduceMotion {
            proxy.scrollTo(ids[next])
        } else {
            withAnimation(GlassMotion.selection) { proxy.scrollTo(ids[next]) }
        }
    }
}

/// One note on the list panel: a plain line with soft fills for hover and selection.
@MainActor
private struct NoteListRow: View {
    static let height: CGFloat = 64

    let note: NoteRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassTokens.Radius.card - 4, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: note.displayTitle)
                        .font(GlassFont.ui(14, .semibold))
                        .foregroundStyle(GlassColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if note.hasAudio, note.audioDuration > 0 {
                        Text(verbatim: MeetingTime.clock(note.audioDuration))
                            .font(GlassFont.ui(13, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textSecondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: MeetingDateText.short(note.createdAt))
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if note.transcriptError != nil {
                        GlassBadge("Bez tekstu", systemImage: "exclamationmark.triangle", tone: .warning)
                    } else if note.hasAudio {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GlassColor.textSecondary)
                            .accessibilityLabel(Text("Notatka głosowa"))
                    }
                }
                .frame(height: 22)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                shape.fill(GlassColor.accent.opacity(0.26))
                    .overlay { shape.strokeBorder(GlassColor.accent.opacity(0.7), lineWidth: 1) }
            } else if isHovered {
                shape.fill(Color.white.opacity(0.06))
            }
        }
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

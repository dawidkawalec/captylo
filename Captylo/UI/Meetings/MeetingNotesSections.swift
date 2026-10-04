import SwiftUI

/// The rows of `MeetingNotesDocument`: per section a header and its rows. The row marker sits in
/// the header's icon column, so the row text lines up with the section title. Each `[mm:ss]`
/// citation is a stamp on the right of its row that plays that moment (plain text without
/// `onPlay`). Used by "Notatki AI" and for the answers in "Zapytaj".
@MainActor
struct MeetingNotesSections: View {
    let document: MeetingNotesDocument
    @Binding var toggledTasks: Set<Int>
    let onPlay: ((Double) -> Void)?

    /// Width of `GlassSectionHeader`'s icon column, and its spacing to the title.
    private static let markerWidth: CGFloat = 22
    private static let markerSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 0) {
                    if let title = section.title {
                        GlassSectionHeader(title: Text(verbatim: title), systemImage: Self.symbol(for: title))
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(GlassColor.separator)
                                .frame(height: 1)
                                .padding(.leading, Self.markerWidth + Self.markerSpacing)
                        }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: MeetingNotesDocument.Item) -> some View {
        let done = isDone(item)
        return HStack(alignment: .firstTextBaseline, spacing: Self.markerSpacing) {
            marker(item, done: done)
                .frame(width: Self.markerWidth)
            Text(Self.inline(item.line.text))
                .font(GlassFont.body)
                .foregroundStyle(done ? GlassColor.textTertiary : GlassColor.textPrimary)
                .strikethrough(done, color: GlassColor.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            stamps(item.line.citations)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func marker(_ item: MeetingNotesDocument.Item, done: Bool) -> some View {
        switch item {
        case .bullet:
            Text(verbatim: "•")
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.highlight)
        case .task(let index, _, _):
            Button {
                if toggledTasks.contains(index) {
                    toggledTasks.remove(index)
                } else {
                    toggledTasks.insert(index)
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(done ? GlassColor.success : GlassColor.highlight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done ? Text("Oznacz jako do zrobienia") : Text("Oznacz jako zrobione"))
            .accessibilityLabel(done ? Text("Oznacz jako do zrobienia") : Text("Oznacz jako zrobione"))
        case .paragraph:
            Text(verbatim: " ")
                .font(GlassFont.body)
        }
    }

    @ViewBuilder
    private func stamps(_ citations: [Double]) -> some View {
        if !citations.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(citations.enumerated()), id: \.offset) { _, seconds in
                    if let onPlay {
                        MeetingStampButton(stamp: MeetingTime.stamp(seconds)) {
                            onPlay(seconds)
                        }
                    } else {
                        Text(verbatim: MeetingTime.stamp(seconds))
                            .font(GlassFont.ui(12, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textTertiary)
                    }
                }
            }
            .fixedSize()
        }
    }

    private func isDone(_ item: MeetingNotesDocument.Item) -> Bool {
        guard case .task(let index, _, let done) = item else { return false }
        return done != toggledTasks.contains(index)
    }

    /// Line icon of the five fixed sections; a generic list icon for any other heading.
    private static func symbol(for title: String) -> String {
        switch MeetingSearch.fold(title) {
        case "podsumowanie": return "text.alignleft"
        case "decyzje": return "checkmark.seal"
        case "zadania": return "checklist"
        case "otwarte pytania": return "questionmark.bubble"
        case "nastepne kroki": return "arrow.forward.circle"
        default: return "list.bullet"
        }
    }

    /// Inline Markdown (bold, italics, code); plain text when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

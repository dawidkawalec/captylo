import SwiftUI

/// The hit lines under a meeting row while searching (`MeetingSearchResults`): per line the
/// stamp ("12:34", a note icon for the notes) and the speaker in tertiary, then the snippet with
/// the matched words bold, two lines at most. A click opens that place in the details.
@MainActor
struct MeetingSearchHitsView: View {
    /// Reserved per line (two lines of caption), so a row's height is known before it draws.
    static let lineHeight: CGFloat = 34
    static let spacing: CGFloat = 2

    /// Height of `count` hit lines.
    static func height(lines count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * lineHeight + CGFloat(count - 1) * spacing
    }

    let lines: [MeetingSearchHitLine]
    let onOpen: (MeetingSearchHitLine) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(lines) { line in
                MeetingSearchHitLineButton(line: line) { onOpen(line) }
            }
        }
    }
}

/// One hit line: a plain button with a soft hover fill.
@MainActor
private struct MeetingSearchHitLineButton: View {
    let line: MeetingSearchHitLine
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                marker
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: MeetingSearchHitsView.lineHeight,
                   maxHeight: MeetingSearchHitsView.lineHeight, alignment: .topLeading)
            .background {
                shape.fill(Color.white.opacity(isHovered ? 0.07 : 0))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(help)
    }

    @ViewBuilder
    private var marker: some View {
        switch line.source {
        case .segment(_, let start):
            Text(verbatim: MeetingTime.clock(start))
                .font(GlassFont.ui(11, .medium).monospacedDigit())
                .foregroundStyle(GlassColor.textTertiary)
        case .notes:
            Image(systemName: "note.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(GlassColor.textTertiary)
                .accessibilityHidden(true)
        }
    }

    /// "Anna: ...wyślę **ofertę** jutro...": the label in tertiary, the snippet in secondary with
    /// the matches in primary semibold.
    private var text: AttributedString {
        var label = AttributedString(line.label + ": ")
        label.font = GlassFont.ui(12, .medium)
        label.foregroundColor = GlassColor.textTertiary
        var snippet = line.snippet.attributed
        snippet.font = GlassFont.caption
        snippet.foregroundColor = GlassColor.textSecondary
        let matches = snippet.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map(\.range)
        for range in matches {
            snippet[range].font = GlassFont.ui(12, .semibold)
            snippet[range].foregroundColor = GlassColor.textPrimary
            // The semibold face is the emphasis; no synthetic bold on top of it.
            snippet[range].inlinePresentationIntent = nil
        }
        return label + snippet
    }

    private var help: Text {
        switch line.source {
        case .segment: return Text("Pokaż w transkrypcie")
        case .notes: return Text("Pokaż notatki")
        }
    }
}

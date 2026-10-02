import SwiftUI

/// One exchange of the "Zapytaj wszystkie spotkania" panel: the question in its bubble, a note
/// when only the AI notes were searched (the index is being built), the answer line by line with
/// its `[S1 12:34]` citations as buttons on the right (`LibraryCitationButton`), and "Źródła",
/// the meetings it was answered from (S1 first), each a button that opens the meeting. A failure
/// shows as a status line, with "Dodaj klucz" when the AI key is missing.
@MainActor
struct LibraryAnswerView: View {
    let answer: LibraryAnswer
    /// Opens a meeting, at that second of its transcript when given.
    let onOpen: (_ meetingID: UUID, _ seconds: Double?) -> Void
    let onAddKey: () -> Void

    private static let markerWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MeetingQuestionBubble(text: answer.question)
            if answer.notesOnly {
                ToolStatusLine(text: String(localized: "Szukam tylko w notatkach AI, indeks się buduje."))
            }
            if answer.hasAnswer, let markdown = answer.answer {
                lines(markdown)
                if !answer.sources.isEmpty {
                    sources
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ToolStatusLine(text: answer.error ?? String(localized: "AI zwróciło pustą odpowiedź."), tone: .error)
                    if answer.error == OpenRouterError.missingKeyMessage {
                        Button("Dodaj klucz", action: onAddKey)
                            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                            .fixedSize()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Answer

    private func lines(_ markdown: String) -> some View {
        let lines = LibraryCitation.lines(markdown, meetings: answer.sources.map(\.meetingID))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if line.isBullet {
                        Text(verbatim: "•")
                            .font(GlassFont.body)
                            .foregroundStyle(GlassColor.highlight)
                            .frame(width: Self.markerWidth)
                    }
                    Text(Self.inline(line.text))
                        .font(GlassFont.body)
                        .foregroundStyle(GlassColor.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    citations(line.citations)
                }
            }
        }
    }

    @ViewBuilder
    private func citations(_ citations: [LibraryCitation]) -> some View {
        if !citations.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                    LibraryCitationButton(label: citation.label, title: title(of: citation.meetingID)) {
                        onOpen(citation.meetingID, citation.seconds)
                    }
                }
            }
            .fixedSize()
        }
    }

    private func title(of meetingID: UUID) -> String {
        answer.sources.first { $0.meetingID == meetingID }?.title ?? ""
    }

    // MARK: Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Źródła")
                .font(GlassFont.caption.weight(.semibold))
                .foregroundStyle(GlassColor.textSecondary)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(answer.sources.enumerated()), id: \.offset) { offset, source in
                Button {
                    onOpen(source.meetingID, nil)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "S\(offset + 1)")
                            .font(GlassFont.ui(12, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textTertiary)
                            .frame(minWidth: 22, alignment: .leading)
                        Text(verbatim: source.title)
                            .font(GlassFont.caption)
                            .foregroundStyle(GlassColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: MeetingDateText.short(source.createdAt))
                            .font(GlassFont.caption)
                            .foregroundStyle(GlassColor.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Otwórz spotkanie"))
            }
        }
        .padding(.top, 4)
    }

    /// Inline Markdown (bold, italics, code); plain text when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

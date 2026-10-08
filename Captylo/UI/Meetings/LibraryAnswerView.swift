import SwiftUI

/// One exchange of the "Zapytaj wszystkie spotkania" panel: the question in its bubble, a note
/// when only the AI notes were searched (the index is being built), the answer line by line with
/// its `[S1 12:34]` citations as buttons on the right (`LibraryCitationButton`), and "Źródła",
/// the meetings it was answered from (S1 first), each a button that opens the meeting. A failure
/// shows as a status line, with "Przejdź na Pro" when there is no AI route.
@MainActor
struct LibraryAnswerView: View {
    let answer: LibraryAnswer
    /// Opens a meeting, at that second of its transcript when given.
    let onOpen: (_ meetingID: UUID, _ seconds: Double?) -> Void
    /// Opens a note in Notatki (`[N1]` and the note rows of "Źródła").
    var onOpenNote: (UUID) -> Void = { _ in }
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
                if !answer.citedSources.isEmpty || !answer.citedNotes.isEmpty {
                    sources
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ToolStatusLine(text: answer.error ?? String(localized: "AI zwróciło pustą odpowiedź."), tone: .error)
                    if answer.error == MeetingSummaryError.noKey.errorDescription {
                        Button("Przejdź na Pro", action: onAddKey)
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
        let lines = LibraryCitation.lines(markdown, meetings: answer.sources.map(\.meetingID), notes: answer.noteSources.map(\.noteID))
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
                    LibraryCitationButton(label: citation.label, title: title(of: citation)) {
                        switch citation.kind {
                        case .meeting:
                            onOpen(citation.targetID, citation.seconds)
                        case .note:
                            onOpenNote(citation.targetID)
                        }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func title(of citation: LibraryCitation) -> String {
        switch citation.kind {
        case .meeting:
            return answer.sources.first { $0.meetingID == citation.targetID }?.title ?? ""
        case .note:
            return answer.noteSources.first { $0.noteID == citation.targetID }?.title ?? ""
        }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Źródła")
                .font(GlassFont.caption.weight(.semibold))
                .foregroundStyle(GlassColor.textSecondary)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(answer.citedSources, id: \.number) { cited in
                let source = cited.source
                sourceRow(label: "S\(cited.number)", title: source.title, date: source.createdAt, help: Text("Otwórz spotkanie")) {
                    onOpen(source.meetingID, nil)
                }
            }
            ForEach(answer.citedNotes, id: \.number) { cited in
                let source = cited.source
                sourceRow(label: "N\(cited.number)", title: source.title, date: source.createdAt, help: Text("Otwórz notatkę")) {
                    onOpenNote(source.noteID)
                }
            }
        }
        .padding(.top, 4)
    }

    private func sourceRow(label: String, title: String, date: Date, help: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: label)
                    .font(GlassFont.ui(12, .medium).monospacedDigit())
                    .foregroundStyle(GlassColor.textTertiary)
                    .frame(minWidth: 22, alignment: .leading)
                Text(verbatim: title)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: MeetingDateText.short(date))
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
        .help(help)
    }

    /// Inline Markdown (bold, italics, code); plain text when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

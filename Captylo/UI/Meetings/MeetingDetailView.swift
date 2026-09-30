import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One meeting on a glass panel: title and when / how long / which app, "Eksportuj" (copy or
/// save Markdown, save JSON, delete) and the tabs "Notatki", "Transkrypt", "Notatki AI". Reads
/// the meeting and its segments from the `Database` actor whenever the selection or
/// `reloadToken` changes; while this meeting records, the transcript follows
/// `MeetingRecorder.liveSegments` and the grey partial lines.
@MainActor
struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Sendable {
        case notes
        case transcript
        case aiNotes

        var title: String {
            switch self {
            case .notes: return String(localized: "Notatki")
            case .transcript: return String(localized: "Transkrypt")
            case .aiNotes: return String(localized: "Notatki AI")
            }
        }

        var symbol: String {
            switch self {
            case .notes: return "note.text"
            case .transcript: return "text.quote"
            case .aiNotes: return "sparkles"
            }
        }
    }

    private struct LoadKey: Equatable {
        let meetingID: UUID
        let reloadToken: Int
    }

    private struct Notice: Equatable {
        let id = UUID()
        let text: String
        let tone: InlineStatus.Tone
    }

    private enum ExportFormat {
        case markdown
        case json

        var fileExtension: String { self == .markdown ? "md" : "json" }
        var contentType: UTType { self == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .json }
    }

    let meetingID: UUID
    /// Bumped by the section after every list reload (search, recorder phase, a finished or
    /// deleted meeting), so the details catch the status, length and AI notes of a stop.
    let reloadToken: Int
    let database: Database
    let recorder: MeetingRecorder
    @Binding var tab: Tab
    let onCopy: (String) -> Void
    let onDelete: (UUID) -> Void

    @State private var meeting: MeetingRecord?
    @State private var segments: [MeetingSegmentRecord] = []
    @State private var notice: Notice?

    /// The recorder works on this meeting (recording or finishing it).
    private var isLive: Bool { recorder.currentMeetingID == meetingID }

    var body: some View {
        GlassPanel(spacing: 14) {
            if let meeting, meeting.id == meetingID {
                header(meeting)
                if let notice {
                    ToolStatusLine(text: notice.text, tone: notice.tone)
                        .transition(.opacity)
                }
                GlassSegmentedPicker(selection: $tab, title: { $0.title }, systemImage: { $0.symbol })
                ScrollView {
                    tabContent(meeting)
                        .padding(.top, 6)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.top)
                .mask(Self.edgeFade)
                .frame(maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(GlassMotion.press, value: notice)
        .task(id: LoadKey(meetingID: meetingID, reloadToken: reloadToken)) {
            await load()
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                notice = nil
            }
        }
        .onChange(of: meetingID) { _, _ in
            notice = nil
        }
    }

    private func load() async {
        let database = self.database
        let id = meetingID
        do {
            let record = try await database.meeting(id: id)
            let rows = try await database.segments(meetingID: id)
            guard !Task.isCancelled else { return }
            meeting = record
            segments = rows
        } catch {
            Log.data.error("Meeting fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Scrolled rows fade out under the tabs and toward the panel bottom instead of a hard cut.
    private static var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
        }
    }

    // MARK: Header

    private func header(_ meeting: MeetingRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: meeting.title)
                    .font(GlassFont.display(20))
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(verbatim: metaText(meeting))
                        .font(GlassFont.caption.monospacedDigit())
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                    if meeting.status == .interrupted, !isLive {
                        GlassBadge("Przerwane", systemImage: "exclamationmark.triangle", tone: .warning)
                            .help(Text("Nagrywanie przerwało się w trakcie. Wypowiedzi zapisane do tej chwili zostały."))
                    }
                }
            }
            Spacer(minLength: 8)
            exportMenu(meeting)
        }
    }

    /// "30 września, 14:00 · 47:12 · Zoom". A meeting cut short never stored its length: the
    /// end of its last saved segment stands in for it.
    private func metaText(_ meeting: MeetingRecord) -> String {
        var parts = [MeetingDateText.long(meeting.createdAt)]
        let length = meeting.duration > 0 ? meeting.duration : (segments.map(\.end).max() ?? 0)
        if !isLive, length > 0 {
            parts.append(MeetingTime.clock(length))
        }
        if let app = meeting.appName, !app.isEmpty {
            parts.append(app)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Export

    private func exportMenu(_ meeting: MeetingRecord) -> some View {
        Menu {
            Button {
                onCopy(MeetingExport.markdown(meeting, segments: segments))
                notice = Notice(text: String(localized: "Skopiowano do schowka."), tone: .success)
            } label: {
                Label("Kopiuj jako Markdown", systemImage: "doc.on.doc")
            }
            Button {
                save(meeting, as: .markdown)
            } label: {
                Label("Zapisz jako Markdown...", systemImage: "doc.text")
            }
            Button {
                save(meeting, as: .json)
            } label: {
                Label("Zapisz jako JSON...", systemImage: "curlybraces")
            }
            Divider()
            Button(role: .destructive) {
                onDelete(meeting.id)
            } label: {
                Label("Usuń spotkanie", systemImage: "trash")
            }
            .disabled(isLive)
        } label: {
            MeetingMenuLabel(title: Text("Eksportuj"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Asks where to save and writes the export of the meeting as it is loaded now.
    private func save(_ meeting: MeetingRecord, as format: ExportFormat) {
        let segments = self.segments
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExport.fileName(title: meeting.title, fileExtension: format.fileExtension)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let data: Data
                switch format {
                case .markdown: data = Data(MeetingExport.markdown(meeting, segments: segments).utf8)
                case .json: data = try MeetingExport.json(meeting, segments: segments)
                }
                try data.write(to: url, options: .atomic)
                notice = Notice(text: String(localized: "Zapisano \(url.lastPathComponent)."), tone: .success)
            } catch {
                Log.data.error("Meeting export failed: \(error.localizedDescription, privacy: .public)")
                notice = Notice(text: String(localized: "Nie udało się zapisać pliku: \(error.localizedDescription)"), tone: .error)
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private func tabContent(_ meeting: MeetingRecord) -> some View {
        switch tab {
        case .notes:
            notes(meeting)
        case .transcript:
            if isLive {
                MeetingTranscriptView(meeting: meeting, segments: recorder.liveSegments,
                                      partials: recorder.partials, isLive: true)
            } else {
                MeetingTranscriptView(meeting: meeting, segments: segments)
            }
        case .aiNotes:
            aiNotes(meeting)
        }
    }

    /// The user's notes, read only here; each line with the meeting time it was written at.
    @ViewBuilder
    private func notes(_ meeting: MeetingRecord) -> some View {
        if !meeting.noteLines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(meeting.noteLines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: MeetingTime.stamp(line.at))
                            .font(GlassFont.ui(12, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textTertiary)
                            .frame(width: 50, alignment: .leading)
                        Text(verbatim: line.text)
                            .font(GlassFont.body)
                            .foregroundStyle(GlassColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .textSelection(.enabled)
        } else if !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(verbatim: meeting.notes)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
        } else {
            ToolCaption("Brak notatek do tego spotkania.")
        }
    }

    @ViewBuilder
    private func aiNotes(_ meeting: MeetingRecord) -> some View {
        if let summary = meeting.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MeetingSummaryText(markdown: summary)
        } else if let error = meeting.summaryError, !error.isEmpty {
            ToolStatusLine(text: error, tone: .error)
        } else if isLive || meeting.status == .processing {
            ToolCaption("Notatki AI pojawią się po zakończeniu spotkania.")
        } else {
            ToolCaption("To spotkanie nie ma notatek AI.")
        }
    }
}

/// The AI notes Markdown, line by line: "##" headings as section titles, bullets as rows,
/// "- [ ]" tasks with a circle, inline bold and italics kept.
@MainActor
private struct MeetingSummaryText: View {
    let markdown: String

    private enum Block {
        case heading(String)
        case bullet(String, task: Bool?)
        case text(String)
    }

    var body: some View {
        let blocks = Self.blocks(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let title):
                    Text(Self.inline(title))
                        .font(GlassFont.sectionTitle)
                        .foregroundStyle(GlassColor.textPrimary)
                        .padding(.top, index == 0 ? 0 : 10)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text, let task):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let task {
                            Image(systemName: task ? "checkmark.circle" : "circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(GlassColor.highlight)
                        } else {
                            Text(verbatim: "•")
                                .foregroundStyle(GlassColor.highlight)
                        }
                        Text(Self.inline(text))
                            .foregroundStyle(GlassColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(GlassFont.body)
                case .text(let text):
                    Text(Self.inline(text))
                        .font(GlassFont.body)
                        .foregroundStyle(GlassColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .lineSpacing(2)
        .textSelection(.enabled)
    }

    private static func blocks(_ markdown: String) -> [Block] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : .heading(title)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let body = line.dropFirst(2)
                if body.hasPrefix("[ ] ") { return .bullet(String(body.dropFirst(4)), task: false) }
                if body.lowercased().hasPrefix("[x] ") { return .bullet(String(body.dropFirst(4)), task: true) }
                return .bullet(String(body), task: nil)
            }
            return .text(line)
        }
    }

    /// Inline Markdown (bold, italics, code, links); plain text when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Neutral glass capsule that opens a menu ("Eksportuj"), like "Przetwórz przez AI" in Historia.
@MainActor
private struct MeetingMenuLabel: View {
    let title: Text
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            title
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .font(GlassFont.button.weight(.medium))
        .foregroundStyle(Color.white.opacity(isEnabled ? 0.97 : 0.55))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: GlassTokens.Size.buttonHeightSmall)
        .background {
            Capsule().fill(Color.white.opacity(GlassTokens.Opacity.control + (isHovered && isEnabled ? 0.04 : 0)))
        }
        .overlay {
            Capsule().stroke(GlassColor.rim(top: 0.32, bottom: 0.06), lineWidth: GlassTokens.Size.rimWidth)
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
    }
}

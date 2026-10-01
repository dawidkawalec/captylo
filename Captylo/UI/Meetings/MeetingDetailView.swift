import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One meeting on a glass panel: the title (a click renames it, also while it records) and
/// when / how long / which app, "Eksportuj" (copy or save Markdown, save JSON, delete) and the
/// tabs "Notatki" (the editable notes), "Transkrypt", "Notatki AI". Reads the meeting and its
/// segments from the `Database` actor whenever the selection or `reloadToken` changes.
///
/// While this meeting records, the live bar sits on top (with its warnings and, once per start,
/// the consent card) and the tabs give way to two columns: the live transcript
/// (`MeetingRecorder.liveSegments` and the grey partial lines) and the notes editor, stacked when
/// narrow. Afterwards a `[mm:ss]` stamp (in the transcript or an AI notes citation) plays its
/// track from a second before that moment in the player under the tabs, and a "Mówca N" chip
/// takes a name. "Notatki AI" is `MeetingAINotesView` (Pro notes, or the Pro card in Free).
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

    /// A `[mm:ss]` stamp was clicked: this track plays in the player under the tabs.
    private struct Playback: Equatable {
        let meetingID: UUID
        let track: MeetingTrack
    }

    /// Below this width of the live area the notes go under the live transcript.
    static let liveStackWidth: CGFloat = 520
    /// Height of the notes editor under the live transcript (narrow layout).
    static let stackedNotesHeight: CGFloat = 110

    let meetingID: UUID
    /// Bumped by the section after every list reload (search, recorder phase, a finished or
    /// deleted meeting), so the details catch the status, length and AI notes of a stop.
    let reloadToken: Int
    let database: Database
    let recorder: MeetingRecorder
    let settings: AppSettings
    /// "Notatki AI": Pro shows the notes, Free the Pro card (follows the dev switch live).
    let proAccess: ProAccess
    /// "Wygeneruj ponownie" runs; the section reloads when one finishes.
    let notesRuns: MeetingNotesRuns
    @Binding var tab: Tab
    let onCopy: (String) -> Void
    let onDelete: (UUID) -> Void
    /// Opens Modele: "Dodaj klucz" under a missing-key failure of the AI notes, "Otwórz Modele"
    /// when the speech model fails while recording.
    let onOpenModels: () -> Void
    /// A new title was saved (the saved row): the list shows it without a reload.
    let onRenamed: (MeetingRecord) -> Void
    /// Design preview: the title opens as a field.
    let startsEditingTitle: Bool

    @State private var meeting: MeetingRecord?
    @State private var segments: [MeetingSegmentRecord] = []
    @State private var notice: Notice?
    /// Lives as long as the details do: text typed while a meeting stops survives the switch
    /// from the live columns to the tabs.
    @State private var notesDraft: MeetingNotesDraft
    @State private var player = AudioPlayerModel()
    @State private var playback: Playback?
    @State private var liveWidth: CGFloat = 0

    init(
        meetingID: UUID,
        reloadToken: Int,
        database: Database,
        recorder: MeetingRecorder,
        settings: AppSettings,
        proAccess: ProAccess,
        notesRuns: MeetingNotesRuns,
        tab: Binding<Tab>,
        onCopy: @escaping (String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onOpenModels: @escaping () -> Void,
        onRenamed: @escaping (MeetingRecord) -> Void,
        startsEditingTitle: Bool = false
    ) {
        self.meetingID = meetingID
        self.reloadToken = reloadToken
        self.database = database
        self.recorder = recorder
        self.settings = settings
        self.proAccess = proAccess
        self.notesRuns = notesRuns
        _tab = tab
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onOpenModels = onOpenModels
        self.onRenamed = onRenamed
        self.startsEditingTitle = startsEditingTitle
        _notesDraft = State(initialValue: MeetingNotesDraft(database: database))
    }

    /// The recorder works on this meeting (recording or finishing it).
    private var isLive: Bool { recorder.currentMeetingID == meetingID }

    var body: some View {
        GlassPanel(spacing: 14) {
            if let meeting, meeting.id == meetingID {
                if isLive {
                    MeetingLiveBar(recorder: recorder, onOpenModels: onOpenModels) {
                        Task { await recorder.stop() }
                    }
                    if recorder.isRecording, recorder.showsConsentReminder, settings.meetingsConsentReminder {
                        consentCard
                            .transition(.opacity)
                    }
                }
                header(meeting)
                if let notice {
                    ToolStatusLine(text: notice.text, tone: notice.tone)
                        .transition(.opacity)
                }
                if isLive {
                    liveColumns(meeting)
                } else {
                    GlassSegmentedPicker(selection: $tab, title: { $0.title }, systemImage: { $0.symbol })
                    if tab == .notes {
                        MeetingNotesEditor(draft: notesDraft) { noteTime(meeting) }
                            .padding(.bottom, 4)
                    } else {
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
                    }
                    if let playback, playback.meetingID == meetingID {
                        playbackBar(playback)
                            .transition(.opacity)
                    }
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(GlassMotion.press, value: notice)
        .animation(GlassMotion.press, value: playback)
        .animation(GlassMotion.press, value: recorder.showsConsentReminder)
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
            closePlayback()
        }
        .onDisappear {
            notesDraft.flush()
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
            if let record {
                notesDraft.show(record)
            }
        } catch {
            Log.data.error("Meeting fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The meeting time a new line of notes gets: the recording clock while it records, the
    /// meeting's length afterwards (an interrupted one: the end of its last line).
    private func noteTime(_ meeting: MeetingRecord) -> Double {
        if recorder.isRecording, isLive {
            return recorder.elapsed()
        }
        let lastLine = (isLive ? recorder.liveSegments : segments).map(\.end).max() ?? 0
        return max(meeting.duration, lastLine)
    }

    // MARK: Live

    private var consentCard: some View {
        MeetingConsentCard(
            onCopy: { onCopy(MeetingConsent.disclosure) },
            onNeverShow: {
                settings.meetingsConsentReminder = false
                recorder.dismissConsentReminder()
            },
            onDismiss: { recorder.dismissConsentReminder() }
        )
    }

    /// The live transcript and the notes side by side (stacked below `liveStackWidth`).
    private func liveColumns(_ meeting: MeetingRecord) -> some View {
        let stacked = liveWidth > 0 && liveWidth < Self.liveStackWidth
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        let notesWidth = min(max(liveWidth * 0.42, 220), 320)
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                columnTitle(Text("Transkrypt na żywo"), systemImage: "text.quote")
                ScrollView {
                    MeetingTranscriptView(meeting: meeting, segments: recorder.liveSegments,
                                          partials: recorder.partials, isLive: true)
                        .padding(.top, 6)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom)
                .mask(Self.edgeFade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                columnTitle(Text("Notatki"), systemImage: "note.text")
                MeetingNotesEditor(draft: notesDraft) { noteTime(meeting) }
            }
            .frame(width: stacked ? nil : notesWidth)
            .frame(maxWidth: stacked ? .infinity : nil)
            .frame(height: stacked ? Self.stackedNotesHeight : nil)
            .frame(maxHeight: stacked ? nil : .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            liveWidth = width
        }
    }

    private func columnTitle(_ title: Text, systemImage: String) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
        }
        .font(GlassFont.ui(12, .medium))
        .foregroundStyle(GlassColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Playback

    private func play(_ track: MeetingTrack, from start: Double) {
        let url = AppPaths.meetingTrackURL(meetingID, track: track)
        playback = Playback(meetingID: meetingID, track: track)
        player.play(url, from: max(0, start - 1))
    }

    /// An AI notes citation: the track of the line spoken at that second (the other side when
    /// the meeting has no lines), from a second before it, like a transcript stamp.
    private func playCitation(at seconds: Double) {
        play(MeetingCitations.track(at: seconds, in: segments) ?? .them, from: seconds)
    }

    private func closePlayback() {
        player.stop()
        playback = nil
    }

    /// Which track plays, the capsule player and a close button.
    private func playbackBar(_ playback: Playback) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: playback.track.defaultLabel)
                .font(GlassFont.ui(12, .medium))
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
            AudioPlayerView(url: AppPaths.meetingTrackURL(playback.meetingID, track: playback.track), player: player)
            ToolIconButton("xmark", label: Text("Zamknij odtwarzacz"), size: 26) {
                closePlayback()
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Speakers

    /// Stores the name in one step on the database actor (the AI notes may be writing the same
    /// row) and shows the saved record.
    private func rename(speaker label: String, to name: String) {
        let database = self.database
        let id = meetingID
        Task {
            do {
                let saved = try await database.modifyMeeting(id: id) { record in
                    if name.isEmpty {
                        record.speakerNames.removeValue(forKey: label)
                    } else {
                        record.speakerNames[label] = name
                    }
                }
                if let saved, saved.id == meetingID {
                    meeting = saved
                }
            } catch {
                Log.data.error("Speaker name could not be saved: \(error.localizedDescription, privacy: .public)")
                notice = Notice(text: String(localized: "Nie udało się zapisać imienia."), tone: .error)
            }
        }
    }

    // MARK: Title

    /// Shows the typed title at once and saves it in one step on the database actor (the notes
    /// and the AI notes may be writing the same row), then hands the saved row to the list.
    /// Everything comes from the editor that was open, so a field still open when another
    /// meeting is picked (the editor saves as it goes away) still renames its own meeting.
    private func rename(_ id: UUID, from current: String, to typed: String) {
        guard let title = MeetingRecord.editedTitle(typed, current: current) else { return }
        if meeting?.id == id {
            meeting?.title = title
        }
        let database = self.database
        Task {
            do {
                guard let saved = try await database.modifyMeeting(id: id, { $0.title = title }) else { return }
                if meeting?.id == saved.id {
                    meeting = saved
                }
                onRenamed(saved)
            } catch {
                Log.data.error("Meeting title could not be saved: \(error.localizedDescription, privacy: .public)")
                if meeting?.id == id {
                    meeting?.title = current
                }
                notice = Notice(text: String(localized: "Nie udało się zapisać tytułu."), tone: .error)
            }
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
                // While live every line of height goes to the transcript and the notes.
                MeetingTitleEditor(title: meeting.title, lineLimit: isLive ? 1 : 2, startsEditing: startsEditingTitle) { typed in
                    rename(meeting.id, from: meeting.title, to: typed)
                }
                .id(meeting.id)
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

    /// "Transkrypt" and "Notatki AI" (scrolled by the caller); "Notatki" is the editor, which
    /// scrolls itself.
    @ViewBuilder
    private func tabContent(_ meeting: MeetingRecord) -> some View {
        switch tab {
        case .notes:
            EmptyView()
        case .transcript:
            MeetingTranscriptView(
                meeting: meeting,
                segments: segments,
                onPlay: meeting.hasAudio ? { track, start in play(track, from: start) } : nil,
                onRename: { label, name in rename(speaker: label, to: name) }
            )
        case .aiNotes:
            aiNotes(meeting)
        }
    }

    /// Pro notes, the Pro card in Free (`MeetingAINotesView`). A new meeting starts with the
    /// template menu and the checked tasks reset.
    private func aiNotes(_ meeting: MeetingRecord) -> some View {
        let id = meeting.id
        return MeetingAINotesView(
            meeting: meeting,
            isPro: proAccess.isPro,
            isPending: isLive || meeting.status == .processing,
            isRunning: notesRuns.isRunning(id),
            onRegenerate: { templateID in
                notesRuns.regenerate(meetingID: id, templateID: templateID)
            },
            onCopy: { markdown in
                onCopy(markdown)
                notice = Notice(text: String(localized: "Skopiowano do schowka."), tone: .success)
            },
            onAddKey: onOpenModels,
            onPlay: meeting.hasAudio ? { seconds in playCitation(at: seconds) } : nil
        )
        .id(id)
    }
}

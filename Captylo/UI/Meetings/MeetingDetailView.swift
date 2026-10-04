import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One meeting on a glass panel: the title (a click renames it, also while it records) and
/// when / how long / which app, "Eksportuj" (copy or save Markdown, save JSON, delete) and the
/// tabs "Notatki" (the editable notes), "Transkrypt", "Notatki AI", "Zapytaj". Reads the meeting and its
/// segments from the `Database` actor whenever the selection or `reloadToken` changes.
///
/// While this meeting records, the live bar sits on top (with its warnings and, once per start,
/// the consent card) and the tabs give way to two columns: the live transcript
/// (`MeetingRecorder.liveSegments` and the grey partial lines) and the notes editor, stacked when
/// narrow. Afterwards a `[mm:ss]` stamp (in the transcript or an AI notes citation) plays its
/// track from a second before that moment in the player under the tabs, and a "Mówca N" chip
/// takes a name. "Notatki AI" is `MeetingAINotesView` (Pro notes, or the Pro card in Free),
/// "Zapytaj" is `MeetingAskView` (questions about this meeting, Pro), whose citations play too.
///
/// A search hit line clicked in the list arrives as `jump`: once this meeting and its segments
/// are loaded on "Transkrypt", the transcript scrolls to the line holding the segment and lights
/// it up for `highlightDuration`.
@MainActor
struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Sendable {
        case notes
        case transcript
        case aiNotes
        case ask

        var title: String {
            switch self {
            case .notes: return String(localized: "Notatki")
            case .transcript: return String(localized: "Transkrypt")
            case .aiNotes: return String(localized: "Notatki AI")
            case .ask: return String(localized: "Zapytaj")
            }
        }

        var symbol: String {
            switch self {
            case .notes: return "note.text"
            case .transcript: return "text.quote"
            case .aiNotes: return "sparkles"
            case .ask: return "bubble.left.and.text.bubble.right"
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

    /// What a pending jump waits for: the click itself, this meeting and its lines loaded, and
    /// the transcript tab on screen.
    private struct JumpKey: Equatable {
        let jumpID: UUID?
        let loadedMeetingID: UUID?
        let segmentCount: Int
        let tab: Tab
    }

    /// How long the line a search hit jumped to stays lit before it fades.
    static let highlightDuration: Duration = .seconds(1.5)
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
    /// "Zapytaj" questions being answered; the section reloads when one finishes.
    let askRuns: MeetingAskRuns
    /// "Popraw" above the transcript (Pro): cloud again, AI fix, restore.
    let transcriptRuns: MeetingTranscriptRuns
    @Binding var tab: Tab
    let onCopy: (String) -> Void
    let onDelete: (UUID) -> Void
    /// "Usuń tylko nagranie": the section confirms, removes the track files and reloads.
    let onDeleteAudio: (UUID) -> Void
    /// Opens Modele (its Pro card): "Przejdź na Pro" under a no-access failure of the AI notes, "Otwórz Modele"
    /// when the speech model fails while recording.
    let onOpenModels: () -> Void
    /// A new title was saved (the saved row): the list shows it without a reload.
    let onRenamed: (MeetingRecord) -> Void
    /// Design preview: the title opens as a field.
    let startsEditingTitle: Bool
    /// The last search hit line clicked in the list (any meeting); acted on once.
    let jump: MeetingTranscriptJump?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var meeting: MeetingRecord?
    /// The segment whose line is lit up after a jump; back to nil after `highlightDuration`.
    @State private var highlightedSegmentID: UUID?
    /// The jump already scrolled to, so a reload never scrolls back to it.
    @State private var handledJumpID: UUID?
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
        askRuns: MeetingAskRuns,
        transcriptRuns: MeetingTranscriptRuns,
        tab: Binding<Tab>,
        onCopy: @escaping (String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onDeleteAudio: @escaping (UUID) -> Void,
        onOpenModels: @escaping () -> Void,
        onRenamed: @escaping (MeetingRecord) -> Void,
        startsEditingTitle: Bool = false,
        jump: MeetingTranscriptJump? = nil
    ) {
        self.meetingID = meetingID
        self.reloadToken = reloadToken
        self.database = database
        self.recorder = recorder
        self.settings = settings
        self.proAccess = proAccess
        self.notesRuns = notesRuns
        self.askRuns = askRuns
        self.transcriptRuns = transcriptRuns
        _tab = tab
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onDeleteAudio = onDeleteAudio
        self.onOpenModels = onOpenModels
        self.onRenamed = onRenamed
        self.startsEditingTitle = startsEditingTitle
        self.jump = jump
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
                    // Four tabs with icons are too wide for a narrow details panel: titles only.
                    ViewThatFits(in: .horizontal) {
                        GlassSegmentedPicker(selection: $tab, title: { $0.title }, systemImage: { $0.symbol })
                        GlassSegmentedPicker(selection: $tab, title: { $0.title })
                    }
                    if tab == .notes {
                        MeetingNotesEditor(draft: notesDraft) { noteTime(meeting) }
                            .padding(.bottom, 4)
                    } else if tab == .ask {
                        ask(meeting)
                    } else {
                        ScrollViewReader { proxy in
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
                            .task(id: JumpKey(jumpID: jump?.id, loadedMeetingID: self.meeting?.id,
                                              segmentCount: segments.count, tab: tab)) {
                                await performJump(proxy)
                            }
                        }
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
        .task(id: highlightedSegmentID) {
            guard highlightedSegmentID != nil else { return }
            try? await Task.sleep(for: Self.highlightDuration)
            if !Task.isCancelled {
                highlightedSegmentID = nil
            }
        }
        .onChange(of: meetingID) { _, _ in
            notice = nil
            highlightedSegmentID = nil
            closePlayback()
        }
        .onChange(of: meeting?.hasAudio) { _, hasAudio in
            // "Usuń tylko nagranie" (or the retention) took the files the player reads.
            if hasAudio == false {
                closePlayback()
            }
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

    /// Scrolls "Transkrypt" to the line of a search hit and lights it up, once per click. Waits
    /// (the task runs again) until the jump's meeting and its segments are loaded here.
    private func performJump(_ proxy: ScrollViewProxy) async {
        guard let jump, jump.id != handledJumpID, jump.meetingID == meetingID, tab == .transcript,
              let meeting, meeting.id == meetingID else { return }
        let items = MeetingTranscriptLines.items(segments, interruptions: meeting.interruptions)
        guard let lineID = MeetingTranscriptLines.lineID(containing: jump.segmentID, in: items) else { return }
        // One frame for a transcript that just appeared to lay out its rows.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        handledJumpID = jump.id
        if reduceMotion {
            proxy.scrollTo(lineID, anchor: .center)
        } else {
            withAnimation(GlassMotion.spring) { proxy.scrollTo(lineID, anchor: .center) }
        }
        highlightedSegmentID = jump.segmentID
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
    static var edgeFade: some View {
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
                    HStack(spacing: 0) {
                        Text(verbatim: metaText(meeting))
                        if !meeting.participants.isEmpty {
                            Text(verbatim: " · ")
                            MeetingParticipantsLabel(participants: meeting.participants)
                        }
                    }
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

    /// "30 września, 14:00 · 47:12 · Zoom" (the header adds "· 3 osoby" after it when the
    /// calendar gave participants). A meeting cut short never stored its length: the end of its
    /// last saved segment stands in for it.
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
                onDeleteAudio(meeting.id)
            } label: {
                Label("Usuń tylko nagranie", systemImage: "waveform.slash")
            }
            // Processing or a transcript run: the speaker labels or the cloud may be reading the track.
            .disabled(isLive || !meeting.hasAudio || meeting.status == .processing || transcriptRuns.kind(meeting.id) != nil)
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

    /// "Transkrypt" and "Notatki AI" (scrolled by the caller); "Notatki" (the editor) and
    /// "Zapytaj" (the conversation over its field) scroll themselves.
    @ViewBuilder
    private func tabContent(_ meeting: MeetingRecord) -> some View {
        switch tab {
        case .notes, .ask:
            EmptyView()
        case .transcript:
            VStack(alignment: .leading, spacing: 14) {
                transcriptBar(meeting)
                MeetingTranscriptView(
                    meeting: meeting,
                    segments: segments,
                    highlightedSegmentID: highlightedSegmentID,
                    onPlay: meeting.hasAudio ? { track, start in play(track, from: start) } : nil,
                    onRename: { label, name in rename(speaker: label, to: name) }
                )
            }
        case .aiNotes:
            aiNotes(meeting)
        }
    }

    /// Where the transcript comes from ("Transkrypt z Maca" / "z chmury", "poprawiony przez AI"),
    /// the run in progress or the last failure, and in Pro the "Popraw" menu. Nothing while the
    /// post-processors still work on the meeting.
    @ViewBuilder
    private func transcriptBar(_ meeting: MeetingRecord) -> some View {
        let running = transcriptRuns.kind(meeting.id)
        let busy = running != nil || meeting.status == .processing
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let running {
                    ProgressView()
                        .controlSize(.small)
                        .tint(GlassColor.textPrimary)
                    Text(verbatim: Self.runningText(running))
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                } else {
                    Text(verbatim: Self.sourceText(meeting))
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if proAccess.allows(.meetingTranscriptCorrection) || proAccess.allows(.cloudMeetingTranscription),
                   !segments.isEmpty || meeting.hasAudio {
                    transcriptMenu(meeting)
                        .disabled(busy)
                }
            }
            if running == nil, let error = meeting.transcriptError {
                ToolStatusLine(text: error, tone: .error)
            }
        }
    }

    private func transcriptMenu(_ meeting: MeetingRecord) -> some View {
        let id = meeting.id
        return Menu {
            Button {
                transcriptRuns.start(.aiFix, meetingID: id)
            } label: {
                Label("Popraw przez AI", systemImage: "wand.and.stars")
            }
            .disabled(segments.isEmpty || !proAccess.allows(.meetingTranscriptCorrection))
            Button {
                transcriptRuns.start(.cloud, meetingID: id)
            } label: {
                Label("Transkrybuj ponownie w chmurze", systemImage: "cloud")
            }
            .disabled(!meeting.hasAudio || !proAccess.allows(.cloudMeetingTranscription))
            if meeting.transcriptAIModel != nil || segments.contains(where: { $0.originalText != nil }) {
                Divider()
                Button {
                    transcriptRuns.start(.restore, meetingID: id)
                } label: {
                    Label("Przywróć transkrypt sprzed poprawek AI", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            MeetingMenuLabel(title: Text("Popraw"), systemImage: "wand.and.stars")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "Transkrypt z Maca" / "Transkrypt z chmury", plus "poprawiony przez AI".
    static func sourceText(_ meeting: MeetingRecord) -> String {
        let source = meeting.transcriptModel == nil
            ? String(localized: "Transkrypt z Maca")
            : String(localized: "Transkrypt z chmury")
        guard meeting.transcriptAIModel != nil else { return source }
        return source + ", " + String(localized: "poprawiony przez AI")
    }

    static func runningText(_ kind: MeetingTranscriptRuns.Kind) -> String {
        switch kind {
        case .cloud: return String(localized: "Transkrybuję w chmurze...")
        case .aiFix: return String(localized: "AI poprawia transkrypt...")
        case .restore: return String(localized: "Przywracam transkrypt...")
        }
    }

    /// Pro notes, the Pro card in Free (`MeetingAINotesView`). A new meeting starts with the
    /// template menu and the checked tasks reset.
    private func aiNotes(_ meeting: MeetingRecord) -> some View {
        let id = meeting.id
        return MeetingAINotesView(
            meeting: meeting,
            isPro: proAccess.allows(.meetingAINotes),
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

    /// "Zapytaj" (Pro; the Pro card in Free). A new meeting starts with an empty field.
    private func ask(_ meeting: MeetingRecord) -> some View {
        let id = meeting.id
        return MeetingAskView(
            meeting: meeting,
            isPro: proAccess.allows(.meetingAsk),
            isRecording: isLive || meeting.status == .recording,
            pendingQuestion: askRuns.pendingQuestion(id),
            onAsk: { question in
                askRuns.ask(meetingID: id, question: question)
            },
            onClear: { clearQuestions(id) },
            onAddKey: onOpenModels,
            onPlay: meeting.hasAudio ? { seconds in playCitation(at: seconds) } : nil
        )
        .id(id)
    }

    /// "Wyczyść" in "Zapytaj": removes the questions in one step on the database actor (an
    /// answer may be saving meanwhile) and shows the saved record.
    private func clearQuestions(_ id: UUID) {
        let database = self.database
        Task {
            do {
                let saved = try await database.modifyMeeting(id: id) { $0.questions = [] }
                if let saved, saved.id == meetingID {
                    meeting = saved
                }
            } catch {
                Log.data.error("Meeting questions could not be cleared: \(error.localizedDescription, privacy: .public)")
                notice = Notice(text: String(localized: "Nie udało się wyczyścić pytań."), tone: .error)
            }
        }
    }
}

import SwiftUI

/// "Spotkania": search and "Nagraj spotkanie" on top, then the meeting list and the details of
/// the selected meeting side by side (stacked below `stackWidth`, the list collapsed to about
/// four rows). Before the first meeting only `MeetingsEmptyState` shows. The list reloads from
/// the `Database` actor whenever the search, the recorder's phase, the last finished meeting, a
/// finished post-processing (speaker labels, AI notes) or a delete changes, or AI notes written
/// again arrive; a reload keeps the selection, or selects the newest meeting. A title renamed in
/// the details updates its row in place.
///
/// With "Kalendarz" on, the "Nadchodzące" strip (`UpcomingMeetingsStrip`) sits under the header
/// (and above the empty state) with today's next events and "Nagraj" on each.
///
/// "Nagraj spotkanie" starts the recorder and the meeting it opens is selected (also when the
/// menu bar started it), so the live bar is on screen; while it records, the button reads
/// "Zakończ spotkanie" in Record red. A start that failed leaves its reason under the header,
/// with "Otwórz Modele" when the speech model is missing.
/// While the live meeting is selected the list steps aside, so the live transcript and the notes
/// have room even in the default 920 x 640 window; a header button brings it back.
@MainActor
struct MeetingsView: View {
    /// Below this content width the list sits above the details.
    static let stackWidth: CGFloat = 760
    static let listWidth: CGFloat = 300
    static let listLimit = 200

    private struct ReloadKey: Equatable {
        let query: String
        let phase: MeetingRecorder.Phase
        let lastFinishedMeetingID: UUID?
        /// The post-processors finished a meeting: its status, speakers and AI notes changed.
        let processed: Int
        let deletions: Int
        /// "Wygeneruj ponownie" finished: new AI notes (or their error) on a row.
        let notesRuns: Int
        /// A transcript action finished (cloud again, AI fix, restore): new lines on a row.
        let transcriptRuns: Int
    }

    @Environment(AppState.self) private var appState

    @State private var query = ""
    @State private var meetings: [MeetingRecord] = []
    @State private var loaded = false
    @State private var selectedID: UUID?
    @State private var tab: MeetingDetailView.Tab = .transcript
    /// Bumped after every list load; the details reload with it.
    @State private var listVersion = 0
    @State private var deletions = 0
    /// Meeting whose "Usuń spotkanie" awaits confirmation.
    @State private var pendingDelete: UUID?
    /// Meeting whose "Usuń tylko nagranie" awaits confirmation.
    @State private var pendingAudioDelete: UUID?
    @State private var columnsWidth: CGFloat = 0
    /// The user brought the list back while a meeting records (reset by every start).
    @State private var showsListWhileLive = false

    var body: some View {
        let recorder = appState.meetingRecorder
        content(recorder)
            .task(id: ReloadKey(
                query: query,
                phase: recorder.phase,
                lastFinishedMeetingID: recorder.lastFinishedMeetingID,
                processed: recorder.processedCount,
                deletions: deletions,
                notesRuns: appState.meetingNotesRuns.finishedCount,
                transcriptRuns: appState.meetingTranscriptRuns.finishedCount
            )) {
                await reload()
            }
            .onAppear {
                // `CAPTYLO_PREVIEW_TAB`: the design preview opens the details on another tab.
                if appState.isDesignPreview, let previewTab = DesignPreviewData.meetingTab() {
                    tab = previewTab
                }
            }
            .onChange(of: recorder.currentMeetingID) { _, id in
                // A start (here or in the menu bar) shows its live bar right away; a search the
                // new meeting does not match would hide it.
                if let id {
                    query = ""
                    selectedID = id
                    showsListWhileLive = false
                }
            }
            .alert("Usunąć spotkanie?", isPresented: isConfirmingDelete) {
                Button("Usuń", role: .destructive) {
                    if let id = pendingDelete {
                        delete(id)
                    }
                    pendingDelete = nil
                }
                Button("Anuluj", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text("Transkrypt, notatki i nagranie znikną z tego Maca.")
            }
            .alert("Usunąć nagranie?", isPresented: isConfirmingAudioDelete) {
                Button("Usuń nagranie", role: .destructive) {
                    if let id = pendingAudioDelete {
                        deleteAudio(id)
                    }
                    pendingAudioDelete = nil
                }
                Button("Anuluj", role: .cancel) {
                    pendingAudioDelete = nil
                }
            } message: {
                Text("Pliki audio znikną z tego Maca. Transkrypt i notatki zostaną, ale spotkania nie da się już odsłuchać.")
            }
    }

    @ViewBuilder
    private func content(_ recorder: MeetingRecorder) -> some View {
        if !loaded {
            Color.clear
        } else if meetings.isEmpty, query.isEmpty {
            MeetingsEmptyState(
                onRecord: recordAction(recorder),
                error: startFailure(recorder),
                onOpenModels: openModelsAction(recorder),
                upcoming: upcomingEvents(),
                onRecordEvent: recordEventAction(recorder)
            )
        } else {
            let upcoming = upcomingEvents()
            VStack(spacing: 0) {
                header(recorder)
                    .mainColumnFrame()
                    .padding(.top, 14)
                if !upcoming.isEmpty {
                    UpcomingMeetingsStrip(events: upcoming, onRecord: recordEventAction(recorder))
                        .mainColumnFrame()
                        .padding(.top, 14)
                }
                if let failure = startFailure(recorder) {
                    startFailureLine(failure, openModels: openModelsAction(recorder))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .mainColumnFrame()
                        .padding(.top, 8)
                }
                if meetings.isEmpty {
                    noResults
                } else {
                    columns(recorder)
                        .mainColumnFrame()
                        .padding(.top, 16)
                        .padding(.bottom, MainShellMetrics.gutter)
                }
            }
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var isConfirmingAudioDelete: Binding<Bool> {
        Binding(
            get: { pendingAudioDelete != nil },
            set: { if !$0 { pendingAudioDelete = nil } }
        )
    }

    // MARK: Header

    private func header(_ recorder: MeetingRecorder) -> some View {
        HStack(spacing: 10) {
            ToolSearchField("Szukaj w spotkaniach", text: $query)
                .frame(maxWidth: 360)
            Spacer(minLength: 10)
            if isLiveSelected(recorder) {
                ToolIconButton(
                    "sidebar.left",
                    label: showsListWhileLive ? Text("Ukryj listę spotkań") : Text("Pokaż listę spotkań"),
                    size: GlassTokens.Size.buttonHeightSmall
                ) {
                    showsListWhileLive.toggle()
                }
            }
            MeetingRecordButton(isRecording: recorder.isRecording, action: recordAction(recorder))
        }
    }

    /// The meeting on screen is the one being recorded or finished.
    private func isLiveSelected(_ recorder: MeetingRecorder) -> Bool {
        selectedID != nil && selectedID == recorder.currentMeetingID
    }

    /// Start while idle, stop while recording; nil (disabled) while a start or a stop runs.
    private func recordAction(_ recorder: MeetingRecorder) -> (() -> Void)? {
        if recorder.isStarting { return nil }
        switch recorder.phase {
        case .idle:
            return { Task { await recorder.start() } }
        case .recording:
            return { Task { await recorder.stop() } }
        case .finishing:
            return nil
        }
    }

    /// The calendar events for the "Nadchodzące" strip while "Kalendarz" is on with access
    /// (the strip's own cut: not over, next 12 h, three at most).
    private func upcomingEvents() -> [CalendarEvent] {
        let calendar = appState.meetingCalendar
        guard calendar.isEnabled else { return [] }
        return UpcomingMeetingsStrip.visible(calendar.upcoming, now: Date())
    }

    /// "Nagraj" on an upcoming event: starts the recorder on that event while idle; nil
    /// (disabled) while a meeting records, starts or finishes.
    private func recordEventAction(_ recorder: MeetingRecorder) -> ((CalendarEvent) -> Void)? {
        guard recorder.phase == .idle, !recorder.isStarting else { return nil }
        return { event in Task { await recorder.start(event: event) } }
    }

    /// Why the last start failed, while nothing records (`MeetingRecorder.lastError`).
    private func startFailure(_ recorder: MeetingRecorder) -> String? {
        guard recorder.phase == .idle, !recorder.isStarting, let error = recorder.lastError else { return nil }
        return String(localized: "Nie udało się rozpocząć nagrywania. \(error)")
    }

    /// "Otwórz Modele" next to a start refused for the missing speech model; nil otherwise.
    private func openModelsAction(_ recorder: MeetingRecorder) -> (() -> Void)? {
        guard recorder.needsSpeechModel, startFailure(recorder) != nil else { return nil }
        return { openModels() }
    }

    private func openModels() {
        appState.windowPresenter.openMain(section: .modele)
    }

    private func startFailureLine(_ failure: String, openModels: (() -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ToolStatusLine(text: failure, tone: .error)
            if let openModels {
                Button("Otwórz Modele") { openModels() }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .fixedSize()
            }
        }
    }

    // MARK: Columns

    /// One layout for every arrangement, so the details keep their identity (and the notes typed
    /// a moment ago) when the list steps aside, comes back or moves above them.
    private func columns(_ recorder: MeetingRecorder) -> some View {
        let stacked = columnsWidth > 0 && columnsWidth < Self.stackWidth
        let showsList = !isLiveSelected(recorder) || showsListWhileLive
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            if showsList {
                list(recorder)
                    .frame(width: stacked ? nil : Self.listWidth)
                    .frame(height: stacked ? MeetingListView.collapsedHeight(rows: meetings.count) : nil)
            }
            detail(recorder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            columnsWidth = width
        }
    }

    private func list(_ recorder: MeetingRecorder) -> some View {
        MeetingListView(meetings: meetings, selection: $selectedID, recorderPhase: recorder.phase)
    }

    @ViewBuilder
    private func detail(_ recorder: MeetingRecorder) -> some View {
        if let id = selectedID {
            MeetingDetailView(
                meetingID: id,
                reloadToken: listVersion,
                database: appState.database,
                recorder: recorder,
                settings: appState.settings,
                proAccess: appState.proAccess,
                notesRuns: appState.meetingNotesRuns,
                transcriptRuns: appState.meetingTranscriptRuns,
                tab: $tab,
                onCopy: { appState.textOutput.copy($0) },
                onDelete: { pendingDelete = $0 },
                onDeleteAudio: { pendingAudioDelete = $0 },
                onOpenModels: { openModels() },
                onRenamed: { saved in
                    if let index = meetings.firstIndex(where: { $0.id == saved.id }) {
                        meetings[index] = saved
                    }
                },
                startsEditingTitle: appState.isDesignPreview && DesignPreviewData.editsMeetingTitle()
            )
        } else {
            GlassPanel(alignment: .center) {
                Spacer(minLength: 0)
                Text("Wybierz spotkanie z listy.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: No results

    private var noResults: some View {
        VStack {
            Spacer(minLength: 0)
            GlassPanel(padding: 32, alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(GlassColor.icon)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text("Brak wyników")
                    .font(GlassFont.display(17))
                    .foregroundStyle(GlassColor.textPrimary)
                Text("Nic nie pasuje do „\(query)”.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 440)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .mainColumnFrame(alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: Data

    private func reload() async {
        let database = appState.database
        let query = self.query
        do {
            let fetched = try await database.meetings(query: query, limit: Self.listLimit)
            guard !Task.isCancelled else { return }
            meetings = fetched
            if selectedID == nil || !fetched.contains(where: { $0.id == selectedID }) {
                selectedID = fetched.first?.id
            }
            listVersion += 1
        } catch {
            Log.data.error("Meetings fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded = true
    }

    /// Removes the row, its segments and the track folder, then selects the meeting that took
    /// its place on the list. Never the meeting being recorded.
    private func delete(_ id: UUID) {
        guard id != appState.meetingRecorder.currentMeetingID else { return }
        let database = appState.database
        // The design preview never touches the data folder.
        let removesFiles = !appState.isDesignPreview
        let ids = meetings.map(\.id)
        let neighbor = ids.firstIndex(of: id).flatMap { index -> UUID? in
            let rest = ids.filter { $0 != id }
            guard !rest.isEmpty else { return nil }
            return rest[min(index, rest.count - 1)]
        }
        Task {
            do {
                try await database.deleteMeeting(id: id)
            } catch {
                Log.data.error("Meeting delete failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if removesFiles {
                await Self.removeFolder(of: id)
            }
            if selectedID == id {
                selectedID = neighbor
            }
            deletions += 1
        }
    }

    /// "Usuń tylko nagranie": the track folder goes, the row stays with `hasAudio` off (the
    /// details drop the play stamps). Never the meeting being recorded or still processed: the
    /// speaker labels read its track.
    private func deleteAudio(_ id: UUID) {
        guard id != appState.meetingRecorder.currentMeetingID else { return }
        let database = appState.database
        let removesFiles = !appState.isDesignPreview
        Task {
            // A folder that is still there keeps `hasAudio`, so the files never stay unreachable.
            if removesFiles, !(await Self.removeFolder(of: id)) {
                return
            }
            do {
                try await database.setMeetingAudioRemoved(ids: [id])
            } catch {
                Log.data.error("Meeting audio row could not be updated: \(error.localizedDescription, privacy: .public)")
            }
            deletions += 1
        }
    }

    /// True when the folder is gone (or was never there).
    @discardableResult
    private static func removeFolder(of id: UUID) async -> Bool {
        let folder = AppPaths.meetingFolder(id)
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: folder)
                return true
            } catch CocoaError.fileNoSuchFile {
                return true
            } catch {
                Log.data.error("Meeting folder could not be removed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
    }
}

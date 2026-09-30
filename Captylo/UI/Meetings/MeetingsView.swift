import SwiftUI

/// "Spotkania": search and "Nagraj spotkanie" on top, then the meeting list and the details of
/// the selected meeting side by side (stacked below `stackWidth`, the list collapsed to about
/// four rows). Before the first meeting only `MeetingsEmptyState` shows. The list reloads from
/// the `Database` actor whenever the search, the recorder's phase, the last finished meeting or
/// a delete changes; a reload keeps the selection, or selects the newest meeting.
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
        let deletions: Int
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
    @State private var columnsWidth: CGFloat = 0

    var body: some View {
        let recorder = appState.meetingRecorder
        content(recorder)
            .task(id: ReloadKey(
                query: query,
                phase: recorder.phase,
                lastFinishedMeetingID: recorder.lastFinishedMeetingID,
                deletions: deletions
            )) {
                await reload()
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
    }

    @ViewBuilder
    private func content(_ recorder: MeetingRecorder) -> some View {
        if !loaded {
            Color.clear
        } else if meetings.isEmpty, query.isEmpty {
            // Recording starts from here once the live bar shows it (never without it).
            MeetingsEmptyState(onRecord: nil)
        } else {
            VStack(spacing: 0) {
                header
                    .mainColumnFrame()
                    .padding(.top, 14)
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ToolSearchField("Szukaj w spotkaniach", text: $query)
                .frame(maxWidth: 360)
            Spacer(minLength: 10)
            MeetingRecordButton(action: nil)
        }
    }

    // MARK: Columns

    private func columns(_ recorder: MeetingRecorder) -> some View {
        let stacked = columnsWidth > 0 && columnsWidth < Self.stackWidth
        return Group {
            if stacked {
                VStack(spacing: 16) {
                    list(recorder)
                        .frame(height: MeetingListView.collapsedHeight(rows: meetings.count))
                    detail(recorder)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    list(recorder)
                        .frame(width: Self.listWidth)
                    detail(recorder)
                }
            }
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
                tab: $tab,
                onCopy: { appState.textOutput.copy($0) },
                onDelete: { pendingDelete = $0 }
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

    private static func removeFolder(of id: UUID) async {
        let folder = AppPaths.meetingFolder(id)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                Log.data.error("Meeting folder could not be removed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}

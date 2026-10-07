import SwiftUI
import UniformTypeIdentifiers

/// "Notatki": search, "Nowa notatka" and "Importuj nagranie" on top, then the list of notes and
/// the selected note side by side (stacked below `stackWidth`). Before the first note only the
/// empty state shows, with the ⌃⌥⌘N hint.
///
/// The list reloads from the `Database` actor when the search, `AppState.notesVersion` (a voice
/// note, a dictated paragraph, an AI pass, an import) or a delete changes. A search of 3+
/// characters asks the search index first (Polish case forms match, best match first), shorter
/// ones or an index still being built use the store's plain `contains` search. A title or text
/// saved in the editor updates its row in place. Audio files dropped on the screen are imported
/// as voice notes (`AppState.noteImportQueue`).
@MainActor
struct NotesView: View {
    static let stackWidth: CGFloat = 760
    static let listWidth: CGFloat = 300
    static let listLimit = 200

    private struct ReloadKey: Equatable {
        let query: String
        let version: Int
        let deletions: Int
        let created: Int
    }

    @Environment(AppState.self) private var appState
    @Environment(MainRouter.self) private var router

    @State private var query = ""
    @State private var notes: [NoteRecord] = []
    @State private var loaded = false
    @State private var selectedID: UUID?
    @State private var deletions = 0
    @State private var created = 0
    @State private var pendingDelete: NoteRecord?
    @State private var columnsWidth: CGFloat = 0
    @State private var isDropTargeted = false

    var body: some View {
        content
            .task(id: ReloadKey(query: query, version: appState.notesVersion, deletions: deletions, created: created)) {
                await reload()
            }
            .onChange(of: router.pendingNoteID) { _, _ in
                takePendingNote()
            }
            .dropDestination(for: URL.self) { urls, _ in
                appState.noteImportQueue.add(urls: urls)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .alert("Usunąć notatkę?", isPresented: isConfirmingDelete) {
                Button("Usuń", role: .destructive) {
                    if let note = pendingDelete {
                        delete(note)
                    }
                    pendingDelete = nil
                }
                Button("Anuluj", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                if pendingDelete?.hasAudio == true {
                    Text("Notatka i jej nagranie znikną z tego Maca.")
                } else {
                    Text("Notatka zniknie z tego Maca.")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear
        } else if notes.isEmpty, query.isEmpty, !isImporting {
            emptyState
        } else {
            VStack(spacing: 0) {
                header
                    .mainColumnFrame()
                    .padding(.top, 14)
                if let status = importStatus {
                    ToolStatusLine(text: status.text, tone: status.tone)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mainColumnFrame()
                        .padding(.top, 8)
                }
                if notes.isEmpty {
                    noResults
                } else {
                    columns
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
        HStack(alignment: .top, spacing: 10) {
            ToolSearchField("Szukaj w notatkach", text: $query)
                .frame(maxWidth: 360)
            Spacer(minLength: 10)
            importButton
            newNoteButton
        }
    }

    private var newNoteButton: some View {
        Button {
            createNote()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                Text("Nowa notatka")
            }
        }
        .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        .fixedSize()
    }

    private var importButton: some View {
        Button {
            chooseFiles()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                Text("Importuj nagranie")
            }
        }
        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        .fixedSize()
        .help(Text("Nagranie albo głosówka z komunikatora stanie się notatką z transkryptem"))
    }

    // MARK: Columns

    private var columns: some View {
        let stacked = columnsWidth > 0 && columnsWidth < Self.stackWidth
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            NoteListView(notes: notes, selection: $selectedID)
                .frame(width: stacked ? nil : Self.listWidth)
                .frame(height: stacked ? 4 * 64 + 3 + 12 : nil)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            columnsWidth = width
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID {
            NoteDetailView(
                noteID: id,
                reloadToken: appState.notesVersion,
                database: appState.database,
                actions: appState.noteActions,
                dictation: appState.dictationController,
                aiModes: appState.settings.aiModes,
                onSaved: { saved in
                    if let index = notes.firstIndex(where: { $0.id == saved.id }) {
                        notes[index] = saved
                    }
                },
                onDelete: { pendingDelete = $0 }
            )
            .id(id)
        } else {
            GlassPanel(alignment: .center) {
                Spacer(minLength: 0)
                Text("Wybierz notatkę z listy.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Empty and no results

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            GlassPanel(padding: 32, alignment: .center, spacing: 12) {
                GlassIconBadge(systemImage: MainSection.notatki.symbol, size: 52, tint: GlassColor.accent)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text("Tu pojawią się Twoje notatki.")
                    .font(GlassFont.display(17))
                    .foregroundStyle(GlassColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Napisz notatkę albo naciśnij ⌃⌥⌘N w dowolnej aplikacji i powiedz, co chcesz zapamiętać.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    newNoteButton
                    importButton
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 440)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .mainColumnFrame(alignment: .center)
        .padding(.vertical, 24)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: GlassTokens.Radius.panel, style: .continuous)
                    .strokeBorder(GlassColor.accent.opacity(0.8), lineWidth: 2)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

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

    // MARK: Import

    private var isImporting: Bool {
        appState.noteImportQueue.isProcessing
    }

    /// "Przepisuję nagrania..." while the import queue works, then what failed or was skipped.
    private var importStatus: (text: String, tone: InlineStatus.Tone)? {
        let queue = appState.noteImportQueue
        if queue.isProcessing {
            let left = queue.items.filter { $0.status.isActive || $0.status == .waiting }.count
            return (String(localized: "Przepisuję nagrania: \(left)"), .neutral)
        }
        if let failed = queue.items.first(where: { if case .failed = $0.status { return true } else { return false } }) {
            return (String(localized: "Nie udało się zaimportować: \(failed.name)"), .error)
        }
        if let rejected = queue.rejectedNames.first {
            return (String(localized: "Ten plik nie jest nagraniem: \(rejected)"), .error)
        }
        return nil
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Ogg/Opus voice messages, plus `.data` for the ones saved without a name extension.
        let voiceNotes = ["org.xiph.ogg-audio", "org.xiph.opus"].compactMap { UTType($0) }
        panel.allowedContentTypes = [.audio, .movie] + voiceNotes + [.data]
        panel.message = String(localized: "Wybierz nagrania, z których powstaną notatki")
        panel.prompt = String(localized: "Importuj")
        let queue = appState.noteImportQueue
        Task {
            guard await panel.begin() == .OK else { return }
            queue.add(urls: panel.urls)
        }
    }

    // MARK: Data

    private func reload() async {
        let database = appState.database
        let index = appState.meetingSearchIndex
        let query = self.query
        do {
            let rows: [NoteRecord]
            if let terms = SearchQuery.terms(query),
               let hits = await index.noteHits(terms: terms, all: true, limit: Self.listLimit) {
                rows = try await database.notes(ids: hits.map(\.noteID))
            } else {
                rows = try await database.notes(query: query, limit: Self.listLimit)
            }
            guard !Task.isCancelled else { return }
            notes = rows
            if let current = selectedID, !rows.contains(where: { $0.id == current }), query.isEmpty {
                selectedID = rows.first?.id
            } else if selectedID == nil {
                selectedID = rows.first?.id
            }
        } catch {
            Log.data.error("Notes fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded = true
        takePendingNote()
    }

    /// `MainRouter.pendingNoteID` (the "Otwórz" of "Zapisano notatkę"): select it once, clearing
    /// a search that would hide it.
    private func takePendingNote() {
        guard loaded, let id = router.pendingNoteID else { return }
        router.pendingNoteID = nil
        if !notes.contains(where: { $0.id == id }) {
            query = ""
            created += 1
        }
        selectedID = id
    }

    private func createNote() {
        let note = NoteRecord()
        let database = appState.database
        Task {
            do {
                try await database.createNote(note)
            } catch {
                Log.data.error("Creating a note failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            query = ""
            selectedID = note.id
            created += 1
        }
    }

    /// Deletes the note with its recording, then selects the note that took its place.
    private func delete(_ note: NoteRecord) {
        let ids = notes.map(\.id)
        let neighbor = ids.firstIndex(of: note.id).flatMap { index -> UUID? in
            let rest = ids.filter { $0 != note.id }
            guard !rest.isEmpty else { return nil }
            return rest[min(index, rest.count - 1)]
        }
        let actions = appState.noteActions
        Task {
            await actions.delete(noteID: note.id)
            if selectedID == note.id {
                selectedID = neighbor
            }
            deletions += 1
        }
    }
}

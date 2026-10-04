import AppKit
import SwiftData
import SwiftUI

/// "Historia": searchable, paged list of dictations with expandable rows, multi-select delete
/// and CSV export, as glass cards on the dusk wallpaper. An expanded row shows the original
/// transcript next to the AI version, what AI did ("AI: ...", "AI pominięte: ...", "Bez AI") and
/// "Przetwórz przez AI". `HistoryList` reloads its page from the `Database` actor when the search
/// text, the page limit or `statsVersion` (bumped after every save, retranscribe, AI run or
/// delete) changes.
@MainActor
struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var limit = HistorySearch.pageSize
    @State private var selection: Set<UUID> = []
    @State private var expandedID: UUID?
    @State private var busyIDs: Set<UUID> = []
    @State private var rowMessages: [UUID: String] = [:]
    /// Rows with a "Przetwórz przez AI" run in flight, with the name of the mode it uses.
    @State private var aiRuns: [UUID: String] = [:]
    /// Last "Przetwórz przez AI" failure per row (no key, deadline, HTTP error...).
    @State private var aiMessages: [UUID: String] = [:]
    @State private var confirmBulkDelete = false
    /// Row whose "Usuń" awaits confirmation (the delete is irreversible, like the bulk one).
    @State private var pendingDelete: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
                .mainColumnFrame()
                .padding(.top, 14)
                .padding(.bottom, 2)
            // No `.id` here: the list keeps its identity across reloads, so scroll position, the
            // expanded row and a playing recording survive a save, retranscribe or delete.
            HistoryList(
                database: appState.database,
                query: search,
                limit: limit,
                refreshToken: appState.statsVersion,
                selection: $selection,
                expandedID: $expandedID,
                busyIDs: busyIDs,
                rowMessages: rowMessages,
                aiModes: appState.settings.aiModes,
                aiRuns: aiRuns,
                aiMessages: aiMessages,
                expandsSampleRow: appState.isDesignPreview,
                onShowMore: { limit += HistorySearch.pageSize },
                onCopy: { appState.historyActions.copy($0) },
                onReveal: { appState.historyActions.revealInFinder(fileName: $0) },
                onRetranscribe: retranscribe,
                onReprocess: reprocess,
                onDelete: { pendingDelete = $0 }
            )
        }
        .alert("Usunąć zaznaczone wpisy?", isPresented: $confirmBulkDelete) {
            Button("Usuń", role: .destructive) {
                delete(ids: Array(selection))
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Usuniętych wpisów i nagrań nie da się przywrócić. Statystyki na pulpicie pozostaną bez zmian.")
        }
        .alert("Usunąć ten wpis?", isPresented: isConfirmingRowDelete) {
            Button("Usuń", role: .destructive) {
                if let id = pendingDelete {
                    delete(ids: [id])
                }
                pendingDelete = nil
            }
            Button("Anuluj", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("Wpisu i nagrania nie da się przywrócić. Statystyki na pulpicie pozostaną bez zmian.")
        }
    }

    private var isConfirmingRowDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HistorySearchField(text: $search)
                .frame(maxWidth: 360)
                .onChange(of: search) { _, _ in
                    limit = HistorySearch.pageSize
                    expandedID = nil
                }

            Spacer(minLength: 10)

            if !selection.isEmpty {
                Text("Zaznaczono: \(selection.count)")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .transition(.opacity)
            }
            // Selection actions appear only once something is selected: a dimmed button with
            // nothing to act on reads as broken.
            if !selection.isEmpty {
                Button {
                    Task { await appState.historyActions.exportCSV(ids: Array(selection)) }
                } label: {
                    Label("Eksportuj CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .help(Text("Eksportuj CSV"))
                .transition(.opacity)


                Button(role: .destructive) {
                    confirmBulkDelete = true
                } label: {
                    Label("Usuń zaznaczone", systemImage: "trash")
                }
                .buttonStyle(.glass(.destructive, size: .small, shape: .capsule))
                .transition(.opacity)
            }
        }
        .frame(height: GlassTokens.Size.buttonHeightSmall + 4)
        .animation(GlassMotion.press, value: selection.isEmpty)
    }

    // MARK: Actions

    private func retranscribe(_ id: UUID) {
        // Not while an AI run is in flight: its result belongs to the text it started from.
        guard !busyIDs.contains(id), aiRuns[id] == nil else { return }
        busyIDs.insert(id)
        rowMessages[id] = nil
        let settings = appState.settings
        let processor = appState.dictionary.processor
        let vocabulary = appState.dictionary.data.vocabulary
        let actions = appState.historyActions
        let language = settings.transcriptionLanguage
        Task {
            let message = await actions.retranscribe(
                id: id,
                engine: settings.sttEngine,
                language: language,
                vocabulary: vocabulary,
                process: { processor.process($0, language: language) }
            )
            busyIDs.remove(id)
            if let message {
                rowMessages[id] = message
            }
        }
    }

    /// "Przetwórz przez AI": the row's original through `mode`; the row reloads with the new AI
    /// version (`statsVersion`), a failure stays as an inline message under the cards.
    private func reprocess(_ id: UUID, mode: AIMode) {
        guard aiRuns[id] == nil, !busyIDs.contains(id) else { return }
        aiRuns[id] = mode.name
        aiMessages[id] = nil
        let actions = appState.historyActions
        Task {
            let message = await actions.reprocessWithAI(id: id, mode: mode)
            aiRuns[id] = nil
            aiMessages[id] = message
        }
    }

    private func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let actions = appState.historyActions
        Task {
            await actions.delete(ids: ids)
            selection.subtract(ids)
            if let expandedID, ids.contains(expandedID) {
                self.expandedID = nil
            }
        }
    }
}

// MARK: - Search

/// Search as a glass capsule on the wallpaper: magnifier, plain field, clear button.
@MainActor
private struct HistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GlassColor.textSecondary)
                .accessibilityHidden(true)
            TextField(
                "Szukaj w transkrypcjach",
                text: $text,
                prompt: Text("Szukaj w transkrypcjach").foregroundStyle(GlassColor.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(GlassFont.body)
            .foregroundStyle(GlassColor.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(GlassColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Wyczyść wyszukiwanie"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassSurface(.panel, in: Capsule(), shadow: false)
    }
}

// MARK: - List

/// Rows are read through the `Database` actor (the context that writes them), reloaded whenever the
/// search, the page limit or `refreshToken` (`statsVersion`) changes. The list itself is never
/// re-created, and rows keep their identity by id.
///
/// Glass cards in a lazy stack instead of a `List`: the system list paints its own (blue) selection
/// highlight behind every row. Selection follows the list conventions by hand: click selects one
/// row, Cmd-click toggles, Shift-click extends a range, double-click or Return expands, the arrow
/// keys move (Shift extends), Cmd+A selects all, Esc clears.
@MainActor
private struct HistoryList: View {
    private struct LoadKey: Equatable {
        let query: String
        let limit: Int
        let refreshToken: Int
    }

    let database: Database
    let query: String
    let limit: Int
    let refreshToken: Int
    @Binding var selection: Set<UUID>
    @Binding var expandedID: UUID?
    let busyIDs: Set<UUID>
    let rowMessages: [UUID: String]
    let aiModes: [AIMode]
    let aiRuns: [UUID: String]
    let aiMessages: [UUID: String]
    /// Design preview only: open one row with an AI version after the first load.
    let expandsSampleRow: Bool
    let onShowMore: () -> Void
    let onCopy: (String) -> Void
    let onReveal: (String) -> Void
    let onRetranscribe: (UUID) -> Void
    let onReprocess: (UUID, AIMode) -> Void
    let onDelete: (UUID) -> Void

    @State private var rows: [DictationRecord] = []
    @State private var loaded = false
    /// Row the last plain click or arrow move landed on (start of Shift ranges).
    @State private var anchorID: UUID?
    /// Where a Shift+arrow range starts: fixed at the first extension until a plain move or click.
    @State private var shiftOrigin: UUID?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .task(id: LoadKey(query: query, limit: limit, refreshToken: refreshToken)) {
                await reload()
            }
    }

    private func reload() async {
        let database = self.database
        let query = self.query
        let limit = self.limit
        do {
            let fetched = try await database.history(query: query, limit: limit)
            guard !Task.isCancelled else { return }
            rows = fetched
            if expandsSampleRow, !loaded, expandedID == nil {
                expandedID = DesignPreviewData.historyRowToExpand(in: fetched)
            }
        } catch {
            Log.data.error("History fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded = true
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear
        } else if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: MainShellMetrics.panelSpacing) {
                        // One glass panel per day, rows with hairlines on it (mockup 03): an even
                        // surface instead of one card per dictation picking up the wallpaper.
                        ForEach(HistoryDays.group(rows, date: \.createdAt)) { day in
                            GlassPanel(padding: 10, spacing: 0) {
                                GlassSectionHeader(title: Text(verbatim: HistoryDays.title(for: day.id)), systemImage: "calendar")
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                                    .padding(.bottom, 8)
                                ForEach(Array(day.items.enumerated()), id: \.element.id) { index, record in
                                    if index > 0 {
                                        GlassRowSeparator()
                                            .padding(.horizontal, 12)
                                    }
                                    row(record)
                                }
                            }
                        }
                        if rows.count >= limit {
                            Button("Pokaż więcej", action: onShowMore)
                                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                                .padding(.top, 6)
                        }
                    }
                    .padding(.top, MainShellMetrics.topFade)
                    .padding(.bottom, 28)
                    .mainColumnFrame()
                    .background {
                        // Clicking the empty space around the cards clears the selection.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selection = [] }
                    }
                }
                .mainEdgeFade()
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    move(by: press.key == .upArrow ? -1 : 1, extending: press.modifiers.contains(.shift), proxy: proxy)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard selection.count == 1, let id = selection.first else { return .ignored }
                    toggleExpanded(id)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !selection.isEmpty else { return .ignored }
                    selection = []
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(rows.map(\.id))
                    return .handled
                }
            }
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        HistoryRow(
            record: record,
            isSelected: selection.contains(record.id),
            isSelecting: !selection.isEmpty,
            isExpanded: expandedID == record.id,
            isBusy: busyIDs.contains(record.id),
            message: rowMessages[record.id],
            aiModes: aiModes,
            aiRunMode: aiRuns[record.id],
            aiMessage: aiMessages[record.id],
            onClick: { click(record.id) },
            onToggleSelection: { toggleSelection(record.id) },
            onToggle: { toggleExpanded(record.id) },
            onCopy: onCopy,
            onReveal: onReveal,
            onRetranscribe: { onRetranscribe(record.id) },
            onReprocess: { onReprocess(record.id, $0) },
            onDelete: { onDelete(record.id) }
        )
        .id(record.id)
    }

    // MARK: Selection

    /// The leading circle: adds or removes one row, like Cmd-click.
    private func toggleSelection(_ id: UUID) {
        isFocused = true
        shiftOrigin = nil
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        anchorID = id
    }

    private func click(_ id: UUID) {
        isFocused = true
        shiftOrigin = nil
        let flags = NSEvent.modifierFlags
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2, !flags.contains(.command), !flags.contains(.shift) {
            selection = [id]
            anchorID = id
            toggleExpanded(id)
            return
        }
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchorID = id
        } else if flags.contains(.shift), let anchorID, let range = indexRange(from: anchorID, to: id) {
            selection = Set(rows[range].map(\.id))
        } else {
            selection = [id]
            anchorID = id
        }
    }

    private func move(by offset: Int, extending: Bool, proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        let current = anchorID.flatMap { ids.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), ids.count - 1)
        } else {
            next = offset > 0 ? 0 : ids.count - 1
        }
        let id = ids[next]
        if extending, let anchorID = selectionAnchorForExtension(), let range = indexRange(from: anchorID, to: id) {
            selection = Set(rows[range].map(\.id))
        } else {
            selection = [id]
            shiftOrigin = nil
        }
        self.anchorID = id
        if reduceMotion {
            proxy.scrollTo(id)
        } else {
            withAnimation(GlassMotion.selection) { proxy.scrollTo(id) }
        }
    }

    private func selectionAnchorForExtension() -> UUID? {
        if shiftOrigin == nil {
            shiftOrigin = anchorID
        }
        return shiftOrigin
    }

    private func indexRange(from a: UUID, to b: UUID) -> ClosedRange<Int>? {
        guard let first = rows.firstIndex(where: { $0.id == a }),
              let second = rows.firstIndex(where: { $0.id == b }) else { return nil }
        return min(first, second)...max(first, second)
    }

    private func toggleExpanded(_ id: UUID) {
        if reduceMotion {
            expandedID = expandedID == id ? nil : id
        } else {
            withAnimation(GlassMotion.spring) {
                expandedID = expandedID == id ? nil : id
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            GlassPanel(padding: 32, alignment: .center, spacing: 12) {
                Image(systemName: query.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(GlassColor.icon)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(query.isEmpty ? "Historia jest pusta" : "Brak wyników")
                    .font(GlassFont.display(17))
                    .foregroundStyle(GlassColor.textPrimary)
                Text(query.isEmpty
                     ? "Przytrzymaj skrót i zacznij mówić. Każde dyktowanie trafi tutaj."
                     : "Nic nie pasuje do „\(query)”.")
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
}

// MARK: - Row

@MainActor
private struct HistoryRow: View {
    /// Selection circle and time columns; the expanded details line up with the text after them.
    private static let selectColumn: CGFloat = 20
    private static let timeColumn: CGFloat = 58
    private static let columnGap: CGFloat = 12

    let record: DictationRecord
    let isSelected: Bool
    /// Some row is selected: every row shows its selection circle.
    let isSelecting: Bool
    let isExpanded: Bool
    let isBusy: Bool
    let message: String?
    let aiModes: [AIMode]
    /// Mode of the "Przetwórz przez AI" run in flight on this row.
    let aiRunMode: String?
    let aiMessage: String?
    let onClick: () -> Void
    let onToggleSelection: () -> Void
    let onToggle: () -> Void
    let onCopy: (String) -> Void
    let onReveal: (String) -> Void
    let onRetranscribe: () -> Void
    let onReprocess: (AIMode) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var isFailed: Bool { record.status == .failed }
    private var aiStatus: HistoryAIStatus { HistoryAIStatus(record: record) }
    private var isAIRunning: Bool { aiRunMode != nil }
    /// Only a finished dictation with text can go through AI again.
    private var canReprocess: Bool {
        record.status == .completed && !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Symbol of the mode a name belongs to in the current list (modes may have been renamed or
    /// deleted since the row was saved).
    private func symbol(forMode name: String?) -> String {
        guard let name, let mode = aiModes.first(where: { $0.name == name }) else { return "sparkles" }
        return mode.symbol
    }

    private var recordingURL: URL? {
        guard let name = record.audioFileName else { return nil }
        let url = AppPaths.recordingURL(fileName: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    var body: some View {
        // A plain line on the day panel; selection and hover are soft fills inside it, never a
        // glass surface of its own.
        let shape = RoundedRectangle(cornerRadius: GlassTokens.Radius.card - 4, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            summary
            if isExpanded {
                details
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                shape.fill(GlassColor.accent.opacity(0.26))
                    .overlay { shape.strokeBorder(GlassColor.accent.opacity(0.7), lineWidth: 1) }
            } else if isHovered {
                shape.fill(Color.white.opacity(0.06))
            }
        }
        .onHover { isHovered = $0 }
        .opacity(isBusy ? 0.6 : 1)
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(isExpanded ? "Zwiń" : "Rozwiń"), onToggle)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            selectionCircle

            VStack(alignment: .leading, spacing: 5) {
                Text(Self.timeText(record.createdAt))
                    .font(GlassFont.ui(13, .semibold).monospacedDigit())
                    .foregroundStyle(GlassColor.textPrimary)
                HStack(spacing: 6) {
                    Text(AudioPlayerView.clock(record.audioDuration))
                        .font(GlassFont.caption.monospacedDigit())
                        .foregroundStyle(GlassColor.textSecondary)
                    if record.source == .file {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(GlassColor.textSecondary)
                            .accessibilityLabel(Text("Z pliku"))
                    }
                }
            }
            .frame(width: Self.timeColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if isFailed {
                    Label(record.errorMessage ?? String(localized: "Transkrypcja nie powiodła się."), systemImage: "exclamationmark.triangle.fill")
                        .font(GlassFont.body)
                        .foregroundStyle(GlassColor.destructive)
                        .lineLimit(2)
                }
                if isExpanded, !isFailed {
                    // The texts move into the cards below; this line says what AI did.
                    HistoryAIStatusLine(status: aiStatus, modeSymbol: symbol(forMode: record.enhancementMode))
                        .padding(.top, 1)
                } else if !record.finalText.isEmpty {
                    Text(record.finalText)
                        .font(GlassFont.body)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .foregroundStyle(isFailed ? GlassColor.textSecondary : GlassColor.textPrimary)
                    // Why AI gave nothing, readable without hovering the chip or expanding.
                    if !isFailed, case .skipped = aiStatus {
                        HistoryAIStatusLine(status: aiStatus, lineLimit: 1)
                    }
                } else if !isFailed {
                    Text("(pusty tekst)")
                        .font(GlassFont.body)
                        .foregroundStyle(GlassColor.textSecondary)
                }
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Transkrybuję ponownie...")
                    }
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                } else if let message {
                    InlineStatus(text: message, tone: .error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if !record.finalText.isEmpty {
                    let showsCopy = isHovered && !isExpanded
                    Button {
                        onCopy(record.finalText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(HistoryIconButtonStyle())
                    .help("Kopiuj tekst")
                    .accessibilityLabel(Text("Kopiuj tekst"))
                    // On hover only (still reachable by VoiceOver): a column of identical
                    // circles on every row is noise; the chevron stays as the row affordance.
                    // Expanded rows copy from their "Oryginał" / "Po AI" cards instead.
                    .opacity(showsCopy ? 1 : 0)
                    .allowsHitTesting(showsCopy)
                    .animation(GlassMotion.selection, value: showsCopy)
                }
                // "AI" / "AI ✕" next to the chevron; an expanded row says it in its status line.
                if !isExpanded {
                    HistoryAIChip(status: aiStatus)
                        .transition(.opacity)
                }
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(HistoryIconButtonStyle())
                .accessibilityLabel(Text(isExpanded ? "Zwiń" : "Rozwiń"))
            }
        }
        .contentShape(Rectangle())
        // Buttons inside keep their own clicks; the rest of the summary selects (see HistoryList).
        .onTapGesture(perform: onClick)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !record.text.isEmpty {
                HistoryVersionCards(
                    original: record.text,
                    aiText: record.enhancedText,
                    aiModeName: record.enhancementMode,
                    aiModeSymbol: symbol(forMode: aiRunMode ?? record.enhancementMode),
                    processingMode: aiRunMode,
                    onCopy: onCopy
                )
            }
            if let aiMessage, !isAIRunning {
                ToolStatusLine(text: aiMessage, tone: .error)
            }
            if let url = recordingURL {
                AudioPlayerView(url: url)
                    .padding(.bottom, 4)
            }
            // One line when it fits; otherwise "Usuń" drops to its own line instead of squeezing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    rowActions
                    Spacer(minLength: 8)
                    deleteButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        rowActions
                    }
                    deleteButton
                }
            }
            metadata
        }
        .padding(.leading, Self.selectColumn + Self.timeColumn + Self.columnGap * 2)
    }

    @ViewBuilder
    private var rowActions: some View {
        if canReprocess {
            HistoryReprocessMenu(modes: aiModes, isProcessing: isAIRunning, onPick: onReprocess)
        }
        if let name = record.audioFileName, recordingURL != nil {
            Button {
                onReveal(name)
            } label: {
                Label("Pokaż w Finderze", systemImage: "folder")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            Button(action: onRetranscribe) {
                Label("Transkrybuj ponownie", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .disabled(isAIRunning)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Label {
                Text("Usuń")
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(GlassColor.destructive)
            }
        }
        // Same as "Usuń" on Modele: neutral glass with a red icon, so a row action never
        // outshouts "Przetwórz przez AI". Red glass stays for confirmations ("Usuń zaznaczone").
        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
    }

    /// Leading circle that selects the row for "Eksportuj CSV" / "Usuń zaznaczone". Shown on
    /// hover and on every row once something is selected, so the bulk actions are discoverable.
    private var selectionCircle: some View {
        let visible = isSelected || isSelecting || isHovered
        return Button(action: onToggleSelection) {
            ZStack {
                if isSelected {
                    Circle().fill(GlassColor.accent)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: Self.selectColumn, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(GlassMotion.press, value: visible)
        .help(isSelected ? Text("Odznacz") : Text("Zaznacz"))
        .accessibilityLabel(isSelected ? Text("Odznacz") : Text("Zaznacz"))
    }

    /// Speech side of the row; the AI side is in the status line above.
    private var metadata: some View {
        HStack(spacing: 12) {
            if let model = record.modelName {
                Text(verbatim: STTEngine.label(forModelName: model))
            }
            if let ms = record.transcriptionMs {
                Text("STT \(ms) ms")
            }
            if let language = record.language {
                Text(language.uppercased())
            }
        }
        .font(GlassFont.ui(11).monospacedDigit())
        .foregroundStyle(GlassColor.textTertiary)
    }

    /// "14:32": the day is in the header of the day panel.
    static func timeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Stats.locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

// MARK: - Days

/// Groups the history page by calendar day (newest first, as the page comes) and names the days:
/// "Dzisiaj", "Wczoraj", "25 września", "25 września 2025" for another year.
enum HistoryDays {
    struct Day<Item>: Identifiable {
        /// Start of the day.
        let id: Date
        let items: [Item]
    }

    static func group<Item>(_ items: [Item], date: (Item) -> Date, calendar: Calendar = .current) -> [Day<Item>] {
        var days: [Day<Item>] = []
        var current: (start: Date, items: [Item])?
        for item in items {
            let start = calendar.startOfDay(for: date(item))
            if let open = current, open.start == start {
                current?.items.append(item)
            } else {
                if let open = current {
                    days.append(Day(id: open.start, items: open.items))
                }
                current = (start, [item])
            }
        }
        if let open = current {
            days.append(Day(id: open.start, items: open.items))
        }
        return days
    }

    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return String(localized: "Dzisiaj")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Wczoraj")
        }
        let style = Date.FormatStyle(locale: Stats.locale).day().month(.wide)
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            return day.formatted(style)
        }
        return day.formatted(style.year())
    }
}

/// Round icon button on a row card (copy, expand): faint white disc, brighter on hover and press.
private struct HistoryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HistoryIconButton(configuration: configuration)
    }
}

@MainActor
private struct HistoryIconButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(GlassFont.ui(12, .semibold))
            .foregroundStyle(Color.white.opacity(isHovered ? 0.95 : 0.75))
            .frame(width: 28, height: 28)
            .background {
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.24 : (isHovered ? 0.16 : 0.08)))
            }
            .overlay {
                Circle().strokeBorder(GlassColor.rim(top: 0.3, bottom: 0.05), lineWidth: 1)
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

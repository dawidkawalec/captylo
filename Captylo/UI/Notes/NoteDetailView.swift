import SwiftUI

/// One note on the right of Notatki: the title field, the recording of a voice note (with
/// "Spróbuj ponownie" when it could not be transcribed), the text editor, and the actions under
/// it: dictate into the note, "Uporządkuj przez AI", "Przywróć oryginał" and delete.
///
/// The text lives in a `NoteDraft` that saves after a pause and when the note is left. When
/// something outside the editor changed the note (`reloadToken`: an AI pass, a dictated
/// paragraph, a retried transcription), the draft is saved first and the note is read again.
@MainActor
struct NoteDetailView: View {
    let noteID: UUID
    /// `AppState.notesVersion`: the note is read again when it changes.
    let reloadToken: Int
    let database: Database
    let actions: NoteActions
    let dictation: DictationController
    let aiModes: [AIMode]
    /// The title or the text was saved: the list updates the row in place.
    let onSaved: (NoteRecord) -> Void
    let onDelete: (NoteRecord) -> Void

    private struct LoadKey: Equatable {
        let noteID: UUID
        let reloadToken: Int
    }

    @State private var note: NoteRecord?
    @State private var draft: NoteDraft?
    @State private var isRunningAI = false
    @State private var isRetrying = false
    @State private var actionError: String?
    /// The note this view started a dictation into (the button then reads "Zakończ dyktowanie").
    @State private var dictatingInto: UUID?

    var body: some View {
        Group {
            if let note, let draft, draft.noteID == note.id {
                content(note, draft: draft)
            } else {
                GlassPanel(alignment: .center) {
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(noteID: noteID, reloadToken: reloadToken)) {
            await load()
        }
        .onDisappear {
            let pending = draft
            Task { await pending?.flush() }
        }
        .onChange(of: dictation.phase) { _, phase in
            if phase == .idle {
                dictatingInto = nil
            }
        }
    }

    /// Something else writes this note right now (AI, a retried transcription, a take into it):
    /// the title and the text are read-only until it lands, so nothing typed meanwhile is lost.
    private func isBusy(_ note: NoteRecord) -> Bool {
        isRunningAI || isRetrying || (dictatingInto == note.id && dictation.phase != .idle)
    }

    private func content(_ note: NoteRecord, draft: NoteDraft) -> some View {
        GlassPanel(alignment: .leading, spacing: 12) {
            titleRow(note, draft: draft)
                .disabled(isBusy(note))
            if let fileName = note.audioFileName {
                let url = AppPaths.noteAudioURL(fileName: fileName)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    AudioPlayerView(url: url)
                }
            }
            if let error = note.transcriptError {
                transcriptErrorRow(error)
            }
            editor(draft)
                .disabled(isBusy(note))
                .opacity(isBusy(note) ? 0.6 : 1)
            actionRow(note)
            if let actionError {
                ToolStatusLine(text: actionError, tone: .error)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func titleRow(_ note: NoteRecord, draft: NoteDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Tytuł",
                text: Binding(get: { draft.title }, set: { draft.edit(title: $0) }),
                prompt: Text(verbatim: note.displayTitle)
            )
            .textFieldStyle(.plain)
            .font(GlassFont.display(19))
            .foregroundStyle(GlassColor.textPrimary)
            Text(verbatim: MeetingDateText.long(note.createdAt))
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
        }
    }

    private func transcriptErrorRow(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ToolStatusLine(text: String(localized: "Nie udało się przepisać nagrania. \(error)"), tone: .error)
            Spacer(minLength: 6)
            Button {
                retry()
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Spróbuj ponownie")
                }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .fixedSize()
            .disabled(isRetrying)
        }
    }

    private func editor(_ draft: NoteDraft) -> some View {
        TextEditor(text: Binding(get: { draft.body }, set: { draft.edit(body: $0) }))
            .font(GlassFont.body)
            .foregroundStyle(GlassColor.textPrimary)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .overlay(alignment: .topLeading) {
                if draft.body.isEmpty {
                    Text("Pisz albo dyktuj. Wszystko zostaje na tym Macu.")
                        .font(GlassFont.body)
                        .foregroundStyle(GlassColor.textTertiary)
                        .padding(.leading, 13)
                        .padding(.trailing, 10)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassSurface(.track, cornerRadius: GlassTokens.Radius.control, shadow: false)
            .accessibilityLabel(Text("Treść notatki"))
    }

    private func actionRow(_ note: NoteRecord) -> some View {
        HStack(spacing: 8) {
            dictateButton(note)
            HistoryReprocessMenu(
                modes: aiModes,
                isProcessing: isRunningAI,
                title: "Uporządkuj przez AI",
                helpText: "Przepisz notatkę wybranym trybem AI",
                onPick: { mode in runAI(mode) }
            )
            if note.originalBody != nil {
                Button("Przywróć oryginał") {
                    restore()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .fixedSize()
                .help(Text("Wróć do tekstu sprzed AI"))
            }
            Spacer(minLength: 6)
            ToolIconButton("trash", label: Text("Usuń notatkę"), size: GlassTokens.Size.buttonHeightSmall) {
                onDelete(note)
            }
        }
    }

    /// "Dyktuj": a take whose text lands at the end of this note; "Zakończ dyktowanie" stops it.
    /// Disabled while another take records or is transcribed.
    private func dictateButton(_ note: NoteRecord) -> some View {
        let isMine = dictatingInto == note.id && dictation.phase != .idle
        return Button {
            if isMine {
                Task { await dictation.stop() }
            } else {
                dictatingInto = note.id
                let pending = draft
                Task {
                    await pending?.flush()
                    await dictation.start(destination: .appendToNote(note.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isMine ? "stop.fill" : "mic.fill")
                Text(isMine ? "Zakończ dyktowanie" : "Dyktuj")
            }
        }
        .buttonStyle(.glass(isMine ? .destructive : .neutral, size: .small, shape: .capsule))
        .fixedSize()
        .disabled(!isMine && dictation.phase != .idle)
        .help(Text("Podyktuj dalszy ciąg tej notatki"))
    }

    // MARK: Actions

    /// Saves the draft, reads the note again and keeps the draft when it still shows the stored
    /// text or holds keystrokes typed during the read; only a change made elsewhere (AI, a
    /// dictated paragraph, a retried transcription) replaces it.
    private func load() async {
        await draft?.flush()
        do {
            guard let fresh = try await database.note(id: noteID) else {
                note = nil
                draft = nil
                return
            }
            note = fresh
            if let draft, draft.noteID == fresh.id, draft.isShowing(fresh) || draft.hasUnsavedChanges {
                return
            }
            let database = database
            let onSaved = onSaved
            draft = NoteDraft(note: fresh) { record in
                do {
                    let title = record.title
                    let body = record.body
                    if let saved = try await database.modifyNote(id: record.id, { $0.title = title; $0.body = body }) {
                        onSaved(saved)
                    }
                } catch {
                    Log.data.error("Saving a note failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            actionError = nil
        } catch {
            Log.data.error("Reading a note failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runAI(_ mode: AIMode) {
        let id = noteID
        isRunningAI = true
        actionError = nil
        Task {
            await draft?.flush()
            actionError = await actions.applyAI(noteID: id, mode: mode)
            isRunningAI = false
        }
    }

    private func restore() {
        let id = noteID
        Task {
            await draft?.flush()
            await actions.restoreOriginal(noteID: id)
        }
    }

    private func retry() {
        let id = noteID
        isRetrying = true
        Task {
            await draft?.flush()
            _ = await actions.retryTranscription(noteID: id)
            isRetrying = false
        }
    }
}

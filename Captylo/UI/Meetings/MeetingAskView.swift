import SwiftUI

/// The "Zapytaj" tab of a finished meeting (Pro): questions about this meeting and the AI's
/// answers, oldest first. Each question sits in a small glass bubble on the right, its answer
/// under it like the AI notes (`MeetingNotesSections`, `[mm:ss]` citations as stamps that play
/// that moment), a failure as a status line ("Dodaj klucz lub Pro" when there is no AI route). While
/// `MeetingAskRuns` answers, the question shows with a spinner "Szukam odpowiedzi...". At the
/// bottom the field "Zapytaj o to spotkanie..." (Return sends); with no questions yet, three
/// suggested questions above it. A trash icon left of the field (confirmed: "Wyczyść") removes
/// the history.
///
/// While the meeting records the tab says it works after the end. Free: a blurred sample under
/// `MeetingProCard`.
@MainActor
struct MeetingAskView: View {
    let meeting: MeetingRecord
    let isPro: Bool
    /// The meeting is still being recorded: nothing to ask about yet.
    let isRecording: Bool
    /// The question `MeetingAskRuns` is answering for this meeting, nil when none.
    let pendingQuestion: String?
    let onAsk: (String) -> Void
    /// Removes every question of the meeting (after the confirmation here).
    let onClear: () -> Void
    /// Opens Modele, where the AI key goes.
    let onAddKey: () -> Void
    /// Play the meeting from this second; nil without a recording (the stamps are plain text).
    var onPlay: ((Double) -> Void)?

    @State private var draft = ""
    @State private var confirmsClear = false

    private static let endID = "ask-end"

    /// Suggested first questions, in the UI language (the answer follows the question's).
    static var suggestions: [String] {
        [
            String(localized: "Co ustaliliśmy?"),
            String(localized: "Jakie są zadania i kto je robi?"),
            String(localized: "O co pytał klient?"),
        ]
    }

    var body: some View {
        if !isPro {
            ScrollView {
                MeetingProCard(
                    title: "Zapytaj jest w Captylo Pro",
                    message: "Zadaj pytanie o spotkanie i dostań krótką odpowiedź z odnośnikami do momentów rozmowy.",
                    systemImage: "bubble.left.and.text.bubble.right"
                ) {
                    Self.proSample
                }
                .padding(.top, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else if isRecording {
            VStack(alignment: .leading) {
                ToolCaption(verbatim: MeetingAsker.recordingMessage)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                conversation
                if meeting.questions.isEmpty, pendingQuestion == nil {
                    suggestionChips
                }
                inputRow
            }
            .padding(.bottom, 4)
            .alert("Wyczyścić pytania?", isPresented: $confirmsClear) {
                Button("Wyczyść", role: .destructive, action: onClear)
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text("Pytania i odpowiedzi o to spotkanie znikną.")
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if meeting.questions.isEmpty, pendingQuestion == nil {
                        ToolCaption("Zapytaj o cokolwiek z tego spotkania. Odpowiedź wskaże momenty rozmowy, z których pochodzi.")
                    }
                    ForEach(meeting.questions) { asked in
                        exchange(asked)
                    }
                    if let pendingQuestion {
                        VStack(alignment: .leading, spacing: 10) {
                            bubble(pendingQuestion)
                            searchingLine
                        }
                        .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                }
                .padding(.top, 6)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .mask(MeetingDetailView.edgeFade)
            .frame(maxHeight: .infinity)
            .animation(GlassMotion.press, value: pendingQuestion)
            .onChange(of: meeting.questions.count) { _, _ in
                withAnimation(GlassMotion.spring) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .onChange(of: pendingQuestion) { _, _ in
                withAnimation(GlassMotion.spring) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
        }
    }

    private func exchange(_ asked: MeetingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            bubble(asked.question)
            if asked.hasAnswer, let answer = asked.answer {
                MeetingNotesSections(
                    document: MeetingNotesDocument(markdown: answer),
                    toggledTasks: .constant([]),
                    onPlay: onPlay
                )
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ToolStatusLine(text: asked.error ?? String(localized: "AI zwróciło pustą odpowiedź."), tone: .error)
                    if asked.error == MeetingSummaryError.noKey.errorDescription {
                        Button("Dodaj klucz lub Pro", action: onAddKey)
                            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                            .fixedSize()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The question on the right, in a small raised glass bubble.
    private func bubble(_ text: String) -> some View {
        MeetingQuestionBubble(text: text)
    }

    private var searchingLine: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textPrimary)
            Text("Szukam odpowiedzi...")
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: Input

    private var suggestionChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
            }
            VStack(alignment: .leading, spacing: 8) {
                chips
            }
        }
    }

    private var chips: some View {
        ForEach(Self.suggestions, id: \.self) { suggestion in
            Button {
                send(suggestion)
            } label: {
                Text(verbatim: suggestion)
                    .lineLimit(1)
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .fixedSize()
        }
    }

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Wyczyść" (an icon, confirmed) when there is a history, the field and the send button.
    private var inputRow: some View {
        HStack(spacing: 8) {
            if !meeting.questions.isEmpty {
                ToolIconButton("trash", label: Text("Usuń pytania i odpowiedzi o to spotkanie"), size: GlassTokens.Size.fieldHeight) {
                    confirmsClear = true
                }
                .disabled(pendingQuestion != nil)
                .help(Text("Usuń pytania i odpowiedzi o to spotkanie"))
            }
            TextField("Zapytaj o to spotkanie...", text: $draft)
                .textFieldStyle(.glass)
                .onSubmit { send(draft) }
                .disabled(pendingQuestion != nil)
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            .fixedSize()
            .disabled(isBlank || pendingQuestion != nil)
            .help(Text("Zapytaj"))
            .accessibilityLabel(Text("Zapytaj"))
        }
    }

    private func send(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingQuestion == nil else { return }
        onAsk(trimmed)
        draft = ""
    }

    // MARK: Pro card

    /// Invented questions and answers behind the Pro card's blur.
    private static var proSample: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(sampleExchanges.enumerated()), id: \.offset) { _, sample in
                VStack(alignment: .leading, spacing: 8) {
                    MeetingQuestionBubble(text: sample.question)
                    MeetingNotesSections(
                        document: MeetingNotesDocument(markdown: sample.answer),
                        toggledTasks: .constant([]),
                        onPlay: nil
                    )
                }
            }
        }
    }

    private static let sampleExchanges: [(question: String, answer: String)] = [
        ("Co ustaliliśmy?", "- Start kampanii w drugim tygodniu miesiąca [12:05]\n- Budżet bez zmian do końca kwartału [15:40]"),
        ("Kto przygotuje ofertę?", "- Mówca 2: dwie oferty agencji do środy [18:02]"),
    ]
}

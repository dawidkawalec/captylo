import SwiftUI

/// The "Notatki AI" tab of a finished meeting.
///
/// Pro: the notes as sections (`MeetingNotesDocument`): each heading like a panel header with a
/// line icon, bullets as rows with hairlines between them, the bullets under "Zadania" as rows
/// with a check circle (checked on screen only in M1), and each `[mm:ss]` citation as a stamp on
/// the right of its row that plays that moment like the transcript's stamps (plain text when the
/// recording is gone). On top: the template menu, the action ("Napisz notatki", "Wygeneruj
/// ponownie", or "Spróbuj ponownie" after a failure; a spinner and "Piszę notatki..." while
/// `MeetingNotesRuns` writes them) and "Kopiuj" (the Markdown). A failure shows its message as a
/// banner, with "Dodaj klucz" when the AI key is missing; earlier notes stay under it.
///
/// Free: a blurred sample of notes under a card "Notatki AI są w Captylo Pro" with "Zobacz Pro"
/// (captylo.com pricing), styled like the sidebar's `SupportCard`.
@MainActor
struct MeetingAINotesView: View {
    let meeting: MeetingRecord
    let isPro: Bool
    /// The meeting is still finishing (its row says "processing"): the notes are on their way.
    let isPending: Bool
    /// "Wygeneruj ponownie" runs for this meeting (`MeetingNotesRuns`).
    let isRunning: Bool
    /// Write the notes again with this template id.
    let onRegenerate: (String) -> Void
    let onCopy: (String) -> Void
    /// Opens Modele, where the AI key goes.
    let onAddKey: () -> Void
    /// Play the meeting from this second; nil without a recording (the stamps are plain text).
    var onPlay: ((Double) -> Void)?

    /// The user's pick in the template menu; nil = the template the notes were written with,
    /// or the one the title picks.
    @State private var templateID: String?
    /// Tasks checked (or unchecked) on screen, by `MeetingNotesDocument` task index.
    @State private var toggledTasks: Set<Int> = []

    var body: some View {
        if isPro {
            proContent
        } else {
            MeetingProCard()
        }
    }

    // MARK: Pro

    private var summary: String? {
        guard let summary = meeting.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    private var failure: String? {
        guard let error = meeting.summaryError, !error.isEmpty else { return nil }
        return error
    }

    private var template: MeetingTemplate {
        if let templateID {
            return BuiltInMeetingTemplates.template(id: templateID)
        }
        if let used = meeting.summaryTemplateID {
            return BuiltInMeetingTemplates.template(id: used)
        }
        return BuiltInMeetingTemplates.pick(forTitle: meeting.title)
    }

    @ViewBuilder
    private var proContent: some View {
        if isPending, summary == nil, !isRunning {
            writingLine
        } else {
            VStack(alignment: .leading, spacing: 16) {
                toolbar
                if let failure, !isRunning {
                    MainBanner(symbol: "exclamationmark.triangle", tone: .warning, text: failure, surface: .raised) {
                        if failure == MeetingSummaryError.noKey.errorDescription {
                            Button("Dodaj klucz", action: onAddKey)
                        }
                    }
                    .transition(.opacity)
                }
                if let summary {
                    MeetingNotesSections(
                        document: MeetingNotesDocument(markdown: summary),
                        toggledTasks: $toggledTasks,
                        onPlay: onPlay
                    )
                    .opacity(isRunning ? 0.4 : 1)
                } else if !isRunning, failure == nil {
                    ToolCaption("To spotkanie nie ma jeszcze notatek AI. Wybierz szablon i napisz je.")
                }
            }
            .animation(GlassMotion.press, value: isRunning)
        }
    }

    private var writingLine: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textPrimary)
            Text("Piszę notatki...")
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Full labels when they fit; in a narrow details panel the template menu shows only the
    /// template's name and "Kopiuj" only its icon.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(compact: false)
            toolbarRow(compact: true)
        }
    }

    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            templateMenu(compact: compact)
            if isRunning {
                writingLine
                    .fixedSize()
            } else {
                Button {
                    onRegenerate(template.id)
                } label: {
                    Label(actionTitle, systemImage: summary == nil && failure == nil ? "sparkles" : "arrow.clockwise")
                }
                .buttonStyle(.glass(summary == nil && failure == nil ? .accent : .neutral, size: .small, shape: .capsule))
                .fixedSize()
            }
            Spacer(minLength: 8)
            if let summary {
                if compact {
                    ToolIconButton("doc.on.doc", label: Text("Kopiuj notatki AI jako Markdown"), size: GlassTokens.Size.buttonHeightSmall) {
                        onCopy(summary)
                    }
                } else {
                    Button {
                        onCopy(summary)
                    } label: {
                        Label("Kopiuj", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .fixedSize()
                    .help(Text("Kopiuj notatki AI jako Markdown"))
                }
            }
        }
    }

    private var actionTitle: LocalizedStringKey {
        if failure != nil { return "Spróbuj ponownie" }
        if summary != nil { return "Wygeneruj ponownie" }
        return "Napisz notatki"
    }

    private func templateMenu(compact: Bool) -> some View {
        let selection = Binding(
            get: { template.id },
            set: { templateID = $0 }
        )
        return Menu {
            Picker(selection: selection) {
                ForEach(BuiltInMeetingTemplates.all) { template in
                    Text(verbatim: template.name).tag(template.id)
                }
            } label: {
                Text("Szablon")
            }
            .pickerStyle(.inline)
        } label: {
            MeetingMenuLabel(
                title: compact ? Text(verbatim: template.name) : Text("Szablon: \(template.name)"),
                systemImage: "doc.text"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isRunning)
        .help(Text("Rodzaj spotkania, pod który AI pisze notatki"))
    }
}

// MARK: - Sections

/// The notes of `MeetingNotesDocument`: per section a header and its rows. The row marker sits
/// in the header's icon column, so the row text lines up with the section title.
@MainActor
private struct MeetingNotesSections: View {
    let document: MeetingNotesDocument
    @Binding var toggledTasks: Set<Int>
    let onPlay: ((Double) -> Void)?

    /// Width of `GlassSectionHeader`'s icon column, and its spacing to the title.
    private static let markerWidth: CGFloat = 22
    private static let markerSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 0) {
                    if let title = section.title {
                        GlassSectionHeader(title: Text(verbatim: title), systemImage: Self.symbol(for: title))
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(GlassColor.separator)
                                .frame(height: 1)
                                .padding(.leading, Self.markerWidth + Self.markerSpacing)
                        }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: MeetingNotesDocument.Item) -> some View {
        let done = isDone(item)
        return HStack(alignment: .firstTextBaseline, spacing: Self.markerSpacing) {
            marker(item, done: done)
                .frame(width: Self.markerWidth)
            Text(Self.inline(item.line.text))
                .font(GlassFont.body)
                .foregroundStyle(done ? GlassColor.textTertiary : GlassColor.textPrimary)
                .strikethrough(done, color: GlassColor.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            stamps(item.line.citations)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func marker(_ item: MeetingNotesDocument.Item, done: Bool) -> some View {
        switch item {
        case .bullet:
            Text(verbatim: "•")
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.highlight)
        case .task(let index, _, _):
            Button {
                if toggledTasks.contains(index) {
                    toggledTasks.remove(index)
                } else {
                    toggledTasks.insert(index)
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(done ? GlassColor.success : GlassColor.highlight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done ? Text("Oznacz jako do zrobienia") : Text("Oznacz jako zrobione"))
            .accessibilityLabel(done ? Text("Oznacz jako do zrobienia") : Text("Oznacz jako zrobione"))
        case .paragraph:
            Text(verbatim: " ")
                .font(GlassFont.body)
        }
    }

    @ViewBuilder
    private func stamps(_ citations: [Double]) -> some View {
        if !citations.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(citations.enumerated()), id: \.offset) { _, seconds in
                    if let onPlay {
                        MeetingStampButton(stamp: MeetingTime.stamp(seconds)) {
                            onPlay(seconds)
                        }
                    } else {
                        Text(verbatim: MeetingTime.stamp(seconds))
                            .font(GlassFont.ui(12, .medium).monospacedDigit())
                            .foregroundStyle(GlassColor.textTertiary)
                    }
                }
            }
            .fixedSize()
        }
    }

    private func isDone(_ item: MeetingNotesDocument.Item) -> Bool {
        guard case .task(let index, _, let done) = item else { return false }
        return done != toggledTasks.contains(index)
    }

    /// Line icon of the five fixed sections; a generic list icon for any other heading.
    private static func symbol(for title: String) -> String {
        switch MeetingSearch.fold(title) {
        case "podsumowanie": return "text.alignleft"
        case "decyzje": return "checkmark.seal"
        case "zadania": return "checklist"
        case "otwarte pytania": return "questionmark.bubble"
        case "nastepne kroki": return "arrow.forward.circle"
        default: return "list.bullet"
        }
    }

    /// Inline Markdown (bold, italics, code); plain text when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Pro card

/// Free: what Pro writes, as a blurred sample, under the card that leads to the pricing.
@MainActor
private struct MeetingProCard: View {
    @Environment(\.openURL) private var openURL

    /// Invented notes behind the blur (never readable, only their shape shows).
    private static let sample = """
    ## Podsumowanie
    - Zespół omówił plan na kolejny kwartał i podział budżetu [0:42]
    - Najwięcej pytań dotyczyło terminu startu kampanii [6:10]
    ## Decyzje
    - Start kampanii w drugim tygodniu miesiąca [12:05]
    ## Zadania
    - Ja: harmonogram do piątku [14:30]
    - Mówca 2: dwie oferty agencji do środy [18:02]
    ## Następne kroki
    - Krótkie spotkanie po otrzymaniu ofert [24:40]
    """

    var body: some View {
        ZStack(alignment: .top) {
            MeetingNotesSections(
                document: MeetingNotesDocument(markdown: Self.sample),
                toggledTasks: .constant([]),
                onPlay: nil
            )
            .blur(radius: 6)
            .opacity(0.55)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            card
                .frame(maxWidth: 400)
                .padding(.top, 48)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassIconBadge(systemImage: "sparkles", size: 30, tint: VTColor.brandViolet)
                .accessibilityHidden(true)
            Text("Notatki AI są w Captylo Pro")
                .font(GlassFont.sectionTitle)
                .foregroundStyle(GlassColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Podsumowanie, decyzje i zadania z każdego spotkania, w Twoim szablonie. Rozpoznawanie, kto mówi.")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Zobacz Pro") {
                openURL(SupportPromo.proURL)
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            .padding(.top, 4)
            #if DEBUG
            Text("Włącz Tryb Pro (dev) w Ustawieniach")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textTertiary)
                .padding(.top, 2)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card)
        .accessibilityElement(children: .contain)
    }
}

import Foundation
import Security
import SwiftData

/// Fake world for `--design-preview`: a wiped defaults suite, an in-memory store with 42
/// dictations over the last 14 days, a temp `dictionary.json`, a seeded key store, the Parakeet
/// status "ready" and a small OpenRouter model list. Nothing here touches the user's data.
@MainActor
enum DesignPreviewData {
    /// Throwaway defaults domain, wiped at every preview start.
    static let suiteName = "com.captylo.app.design-preview"
    /// Keychain service name used only if someone saves a key inside the preview.
    static let keyService = "com.captylo.app.design-preview"
    static let dictationCount = 42
    static let dayRange = 14

    // MARK: AppState

    /// Builds the preview `AppState`. Call before anything reads `AppSettings()` (AppDelegate.init).
    static func makeAppState() -> AppState {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        seed(settings)

        let container: ModelContainer
        do {
            container = try Store.makeInMemoryContainer()
        } catch {
            fatalError("Design preview: in-memory store failed: \(error)")
        }

        let keyStore = KeyStore(
            service: keyService,
            seed: [KeyStore.Account.openRouter: "sk-or-v1-design-preview-0000000000"],
            reader: { _, _ in KeyStore.ReadResult(value: nil, status: errSecItemNotFound) }
        )

        let overrides = AppStateOverrides(
            modelContainer: container,
            dictionaryURL: writeDictionary(),
            keyStore: keyStore,
            systemMuteDefaults: defaults,
            pinnedModelStatus: .ready,
            pinnedAccessibilityTrust: true,
            pinnedPro: !showsFreePlan(),
            isDesignPreview: true
        )
        return AppState(settings: settings, overrides: overrides)
    }

    /// `CAPTYLO_PREVIEW_FREE=1`: the preview shows the Free plan (the Pro card in "Notatki AI");
    /// Pro is pinned on otherwise.
    static func showsFreePlan(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CAPTYLO_PREVIEW_FREE"] == "1"
    }

    /// `CAPTYLO_PREVIEW_TAB=notes|transcript|ai`: the tab the `main-spotkania` details open on
    /// (nil: the app default, "Transkrypt").
    static func meetingTab(environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingDetailView.Tab? {
        switch environment["CAPTYLO_PREVIEW_TAB"]?.lowercased() {
        case "notes": return .notes
        case "transcript": return .transcript
        case "ai": return .aiNotes
        default: return nil
        }
    }

    /// `CAPTYLO_PREVIEW_AUDIO_CHECK=works|noaccess|nothing|failed`: the result the "Dostęp do
    /// dźwięku systemu" row in Ustawienia shows, as if "Sprawdź" had just run (nil: not checked).
    static func audioCheckOutcome(environment: [String: String] = ProcessInfo.processInfo.environment) -> SystemAudioCheck.Outcome? {
        switch environment["CAPTYLO_PREVIEW_AUDIO_CHECK"]?.lowercased() {
        case "works": return .works
        case "noaccess": return .noAccess
        case "nothing": return .nothingPlaying
        case "failed": return .failed(MeetingAudioError.tap(-50).localizedDescription)
        default: return nil
        }
    }

    /// `CAPTYLO_PREVIEW_SCROLL=<0...1>`: how far down a long page opens, 0 the top and 1 the
    /// bottom (Ustawienia is taller than any screen). Clamped; nil leaves the page at the top.
    static func scrollFraction(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = environment["CAPTYLO_PREVIEW_SCROLL"], let value = Double(raw), value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    /// Inserts the sample history and meetings (the dashboard, Historia and Spotkania read them
    /// through `Database`).
    static func populate(_ database: Database, now: Date = Date()) async {
        for record in sampleRecords(now: now) {
            do {
                try await database.save(record)
            } catch {
                Log.data.error("Design preview: sample save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for (meeting, segments) in sampleMeetings(now: now) {
            do {
                try await database.createMeeting(meeting)
                for segment in segments {
                    try await database.appendSegment(segment)
                }
            } catch {
                Log.data.error("Design preview: sample meeting save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Defaults

    private static func freshDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Design preview: cannot open the defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func seed(_ settings: AppSettings) {
        if let style = WindowBackgroundStyle.previewOverride {
            settings.windowBackground = style
        }
        settings.onboardingDone = true
        settings.aiEnabled = true
        settings.aiModel = "openai/gpt-4.1-mini"
        // Built-ins plus one custom mode; "Czyszczenie" stays active.
        settings.aiModes = BuiltInAIModes.all + [sampleCustomMode]
        settings.aiActiveModeID = BuiltInAIModes.cleanupID
        settings.dashboardRange = dayRange
        settings.openRouterModelsCache = try? JSONEncoder().encode(openRouterModels)
        settings.openRouterModelsCachedAt = Date()
    }

    // MARK: Dictionary

    private static func writeDictionary() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "captylo-design-preview-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        let url = folder.appending(path: "dictionary.json")
        let learnedRule = ReplacementRule(triggers: ["supa bejs"], replacement: "Supabase")
        let data = DictionaryData(
            vocabulary: ["Captylo", "Parakeet", "Notion", "Kubernetes", "Figma", "Dawid Kawalec", "PRD", "Supabase", "Honcho"],
            replacements: [
                ReplacementRule(triggers: ["kapytlo", "kaptylo"], replacement: "Captylo"),
                ReplacementRule(triggers: ["pe er de"], replacement: "PRD"),
                ReplacementRule(triggers: ["noszyn"], replacement: "Notion"),
                learnedRule,
            ]
        )
        // Sample self-learning memory next to it (AppState reads learning.json from the same folder).
        // Five days of watched pastes, fewer fixes every day ("Poprawki/100 słów" on Pulpit: 2.4).
        let editStats = (0..<5).map { offset in
            DailyEditStat(
                day: SelfLearning.dayKey(Date(timeIntervalSinceNow: -Double(4 - offset) * 86_400)),
                words: 500,
                changed: 16 - offset * 2
            )
        }
        var learning = LearningData(learned: [
            LearnedTerm(
                pair: TermCorrection(misheard: "supa bejs", correct: "Supabase"),
                source: .edit,
                learnedAt: Date(timeIntervalSinceNow: -3_600),
                ruleID: learnedRule.id,
                addedToVocabulary: true
            ),
            LearnedTerm(
                pair: TermCorrection(misheard: "honczo", correct: "Honcho"),
                source: .voice,
                addedToVocabulary: true
            ),
        ])
        learning.editStats = editStats
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(learning).write(to: folder.appending(path: "learning.json"), options: .atomic)
        } catch {
            Log.data.error("Design preview: dictionary write failed: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    // MARK: OpenRouter fixture

    static let openRouterModels: [OpenRouterModel] = [
        OpenRouterModel(id: "openai/gpt-4.1-mini", name: "OpenAI: GPT-4.1 Mini", promptPrice: 0.0000004, completionPrice: 0.0000016, contextLength: 1_047_576),
        OpenRouterModel(id: "openai/gpt-oss-120b", name: "OpenAI: gpt-oss-120b", promptPrice: 0.00000009, completionPrice: 0.00000045, contextLength: 131_072, supportsReasoning: true),
        OpenRouterModel(id: "google/gemini-2.5-flash-lite", name: "Google: Gemini 2.5 Flash Lite", promptPrice: 0.0000001, completionPrice: 0.0000004, contextLength: 1_048_576),
        OpenRouterModel(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5", promptPrice: 0.000001, completionPrice: 0.000005, contextLength: 200_000),
        OpenRouterModel(id: "mistralai/mistral-small-3.2-24b-instruct", name: "Mistral: Mistral Small 3.2 24B", promptPrice: 0.00000005, completionPrice: 0.0000001, contextLength: 131_072),
        OpenRouterModel(id: "meta-llama/llama-3.3-70b-instruct", name: "Meta: Llama 3.3 70B Instruct", promptPrice: 0.00000013, completionPrice: 0.0000004, contextLength: 131_072),
    ]

    // MARK: History

    private static let texts: [String] = [
        "Dobry pomysł na dzisiejsze spotkanie. Zaczniemy od przeglądu postępów w projekcie, a następnie omówimy kolejne kroki.",
        "Cześć Marta, podsyłam poprawioną wersję oferty. Daj znać, czy zakres prac się zgadza.",
        "Przypomnij mi jutro o dziesiątej, żeby zadzwonić do księgowej w sprawie faktur za wrzesień.",
        "Wdrożenie na staging przeszło bez błędów. Proszę o testy formularza kontaktowego do końca dnia.",
        "Lista zakupów: mleko owsiane, chleb żytni, pomidory, bazylia i dwa awokado.",
        "W nowej wersji aplikacji skrót klawiszowy działa także w trybie pełnoekranowym.",
        "Dziękuję za wczorajszą rozmowę. W załączniku przesyłam notatkę ze spotkania oraz harmonogram.",
        "Musimy uprościć onboarding. Użytkownik powinien nagrać pierwsze zdanie w mniej niż minutę.",
        "Zamówienie numer 4 8 2 1 zostało wysłane kurierem. Przewidywany czas dostawy to dwa dni robocze.",
        "Plan na weekend: rower nad jeziorem w sobotę rano, a w niedzielę obiad u rodziców.",
        "Kod wygląda dobrze, ale dodałbym test dla pustego pliku i dla bardzo długiego nagrania.",
        "Ustalmy budżet kampanii na październik i sprawdźmy, które reklamy konwertowały najlepiej.",
        "Hej, będę dziesięć minut spóźniony, zacznijcie beze mnie.",
        "Podsumowanie sprintu: zamknęliśmy dwanaście zadań, trzy przechodzą na kolejny tydzień.",
    ]

    /// What AI did with a sample text: a version in some mode, or a note why there is none.
    private struct SampleAI {
        var mode: AIMode
        var text: String?
        var note: String?
    }

    /// Keyed by the index into `texts`; the others were dictated with AI off.
    /// Index 0 is the newest row, so the `main-historia` preview shows a skipped row with its
    /// reason above the fold.
    private static var sampleAI: [Int: SampleAI] {
        [
            0: SampleAI(mode: BuiltInAIModes.cleanup, note: EnhancementFailure.deadline(seconds: 3).note),
            1: SampleAI(mode: BuiltInAIModes.cleanup, text: "Cześć Marta, przesyłam poprawioną wersję oferty. Daj znać, czy zakres prac się zgadza."),
            2: SampleAI(mode: BuiltInAIModes.tasks, text: "- [ ] Jutro o 10:00 zadzwonić do księgowej w sprawie faktur za wrzesień"),
            3: SampleAI(mode: BuiltInAIModes.english, text: "The staging deployment went through without errors. Please test the contact form by the end of the day."),
            4: SampleAI(mode: BuiltInAIModes.cleanup, note: EnhancementSkip.noKey.note),
            6: SampleAI(mode: BuiltInAIModes.email, text: "Dzień dobry,\n\ndziękuję za wczorajszą rozmowę. W załączniku przesyłam notatkę ze spotkania oraz harmonogram.\n\nPozdrawiam"),
            7: SampleAI(mode: BuiltInAIModes.organize, text: "Onboarding do uproszczenia:\n- użytkownik nagrywa pierwsze zdanie w mniej niż minutę"),
            9: SampleAI(mode: BuiltInAIModes.cleanup, note: EnhancementFailure.http(status: 401).note),
            10: SampleAI(mode: BuiltInAIModes.cleanup, note: EnhancementFailure.rejected(.tooShort).note),
            12: SampleAI(mode: BuiltInAIModes.cleanup, text: "Hej, spóźnię się około dziesięciu minut. Zacznijcie beze mnie."),
        ]
    }

    /// Row the `main-historia` preview opens: the newest one whose AI version came from a rewrite
    /// mode (the original and the AI card then differ visibly), else the newest with any AI text.
    static func historyRowToExpand(in records: [DictationRecord]) -> UUID? {
        let withAI = records.filter { $0.enhancedText != nil }
        let rewrite = withAI.first { $0.enhancementMode != nil && $0.enhancementMode != BuiltInAIModes.cleanup.name }
        return (rewrite ?? withAI.first)?.id
    }

    /// A user-made mode next to the built-ins, so Modele shows a custom row too.
    static var sampleCustomMode: AIMode {
        AIMode(
            id: UUID(uuidString: "0CA91000-0000-4000-8000-0000000000A1")!,
            name: "Post na LinkedIn",
            symbol: "text.bubble",
            prompt: BuiltInAIModes.customTemplate.replacingOccurrences(
                of: "describe the result you want here, for example \"a short LinkedIn post\"",
                with: "a short LinkedIn post in a friendly, professional tone"
            ),
            kind: .rewrite,
            deadlineSeconds: 8
        )
    }

    /// 42 records spread over the last 14 days (more on weekdays), newest first.
    static func sampleRecords(now: Date, calendar: Calendar = .current) -> [DictationRecord] {
        var generator = SeededGenerator(seed: 0xCA97_1105)
        var records: [DictationRecord] = []
        records.reserveCapacity(dictationCount)
        for index in 0..<dictationCount {
            // Day 0 is today; a slight bias toward recent days makes the trend chart rise.
            let day = min(dayRange - 1, Int(Double(index) / Double(dictationCount) * Double(dayRange)))
            let hour = 8 + Int(generator.next() % 11)
            let minute = Int(generator.next() % 60)
            let startOfDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -day, to: now) ?? now)
            var createdAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay) ?? startOfDay
            if createdAt > now {
                createdAt = now.addingTimeInterval(-Double(index + 1) * 600)
            }
            let textIndex = index % texts.count
            let text = texts[textIndex]
            let ai = sampleAI[textIndex]
            let enhanced = ai?.text
            let words = WordCounter.count(enhanced ?? text)
            // About 150 words per minute of speech plus a little breathing room.
            let duration = Double(words) / 2.4 + Double(generator.next() % 30) / 10
            let isFile = index % 13 == 5
            records.append(DictationRecord(
                createdAt: createdAt,
                text: text,
                enhancedText: enhanced,
                source: isFile ? .file : .dictation,
                audioDuration: (duration * 10).rounded() / 10,
                language: "pl",
                modelName: "Parakeet v3",
                transcriptionMs: 180 + Int(generator.next() % 220),
                enhancementModel: enhanced == nil ? nil : "openai/gpt-4.1-mini",
                enhancementMs: enhanced == nil ? nil : 620 + Int(generator.next() % 500),
                enhancementMode: ai?.mode.name,
                enhancementNote: ai?.note,
                wordCount: words
            ))
        }
        return records
    }

    // MARK: Meetings

    /// Three invented meetings, newest first: "Budżet marketingu Q4" (Zoom, named and numbered
    /// speakers, notes, AI notes with every section), "Standup zespołu" (Teams, no AI notes) and
    /// "Rozmowa z klientem: wdrożenie" (Meet, cut short by a quit: no stored length, a gap).
    static func sampleMeetings(now: Date, calendar: Calendar = .current) -> [(meeting: MeetingRecord, segments: [MeetingSegmentRecord])] {
        // Two hours ago on a five-minute mark, like a meeting from the calendar.
        let budgetStart = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 2 * 3600) / 300).rounded(.down) * 300)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let standupStart = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: yesterday) ?? yesterday
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        let clientStart = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: twoDaysAgo) ?? twoDaysAgo
        return [
            sampleBudgetMeeting(createdAt: budgetStart),
            sampleStandup(createdAt: standupStart),
            sampleClientCall(createdAt: clientStart),
        ]
    }

    private typealias SampleLine = (start: Double, end: Double, track: MeetingTrack, speaker: String?, text: String)

    private static func segments(_ meetingID: UUID, _ lines: [SampleLine]) -> [MeetingSegmentRecord] {
        lines.map {
            MeetingSegmentRecord(meetingID: meetingID, track: $0.track, start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        }
    }

    private static func sampleBudgetMeeting(createdAt: Date) -> (meeting: MeetingRecord, segments: [MeetingSegmentRecord]) {
        var meeting = MeetingRecord(createdAt: createdAt, title: "Budżet marketingu Q4", status: .completed, duration: 2832, appName: "Zoom")
        meeting.noteLines = [
            MeetingNoteLine(text: "wrzesień: 32 tys., ponad połowa na wyszukiwarkę", at: 20),
            MeetingNoteLine(text: "test LinkedIn, 2 grupy, max 5 tys.", at: 118),
            MeetingNoteLine(text: "kreacje: 3 warianty do środy", at: 626),
        ]
        meeting.notes = meeting.noteLines.map(\.text).joined(separator: "\n")
        meeting.speakerNames = ["1": "Anna"]
        meeting.summaryTemplateID = BuiltInMeetingTemplates.general.id
        meeting.summaryModel = "openai/gpt-4.1-mini"
        meeting.summary = """
        ## Podsumowanie
        - We wrześniu wydaliśmy 32 tys. zł, ponad połowę na reklamy w wyszukiwarce [0:12]
        - LinkedIn daje najwięcej zapytań, ale **koszt leada** jest wysoki [0:25]

        ## Decyzje
        - Dwutygodniowy test LinkedIn na dwóch grupach odbiorców, do 5 tys. zł [1:45]
        - Wyniki testu porównamy 15 października [1:58]

        ## Zadania
        - Mówca 2: trzy warianty grafik do testu, do środy [10:20]
        - Ja: zapytać agencję o termin wideo, jutro [22:13]
        - Mówca 2: podesłać podsumowanie liczb po spotkaniu [45:00]

        ## Otwarte pytania
        - Czy agencja zdąży z wideo przed Black Friday? [22:00]

        ## Następne kroki
        - Spotkanie z wynikami testu 15 października [1:58]
        """
        let lines: [SampleLine] = [
            (4, 11, .me, nil, "Dzień dobry, zaczynamy od budżetu na czwarty kwartał. Anna, pokażesz liczby?"),
            (12.5, 24, .them, "1", "Jasne. We wrześniu wydaliśmy trzydzieści dwa tysiące, z czego ponad połowa poszła na reklamy w wyszukiwarce."),
            (25, 31, .them, "1", "Kampania na LinkedIn dała najwięcej zapytań, ale koszt jednego leada wyszedł wysoki."),
            (95, 104, .me, nil, "Czyli w październiku przesuwamy część budżetu z wyszukiwarki na LinkedIn?"),
            (105.5, 117, .them, "2", "Proponuję najpierw test na dwóch grupach odbiorców, dwa tygodnie, maksymalnie pięć tysięcy."),
            (118, 124, .them, "1", "Zgoda, a wyniki porównamy na spotkaniu piętnastego października."),
            (610, 619, .me, nil, "Dobrze. Kto przygotuje nowe kreacje do testu?"),
            (620.5, 630, .them, "2", "Ja przygotuję trzy warianty grafik do środy."),
            (1320, 1331, .them, "1", "Jeszcze jedno: nie wiemy, czy agencja zdąży z wideo przed Black Friday."),
            (1333, 1340, .me, nil, "Zapytam ich jutro i dam znać na kanale zespołu."),
            (2700, 2710, .them, "2", "To wszystko z mojej strony. Podeślę podsumowanie liczb po spotkaniu."),
            (2712, 2716, .me, nil, "Dzięki, do usłyszenia."),
        ]
        return (meeting, segments(meeting.id, lines))
    }

    private static func sampleStandup(createdAt: Date) -> (meeting: MeetingRecord, segments: [MeetingSegmentRecord]) {
        let meeting = MeetingRecord(createdAt: createdAt, title: "Standup zespołu", status: .completed, duration: 724, appName: "Teams")
        let lines: [SampleLine] = [
            (3, 9, .me, nil, "Cześć wszystkim, szybka runda. Ja dziś kończę eksport spotkań."),
            (10, 19, .them, nil, "U mnie poprawki w formularzu płatności, jutro wypuszczamy je na staging."),
            (21, 27, .them, nil, "Ja testuję nową wersję aplikacji na starszym systemie, na razie bez błędów."),
            (240, 248, .me, nil, "Czy ktoś potrzebuje pomocy z przeglądem kodu?"),
            (250, 256, .them, nil, "Tak, zerknij proszę na zmiany w synchronizacji."),
            (700, 705, .me, nil, "Dzięki, to tyle na dziś."),
        ]
        return (meeting, segments(meeting.id, lines))
    }

    private static func sampleClientCall(createdAt: Date) -> (meeting: MeetingRecord, segments: [MeetingSegmentRecord]) {
        // A quit mid-meeting leaves no length (`duration` 0) and the segments saved so far.
        var meeting = MeetingRecord(createdAt: createdAt, title: "Rozmowa z klientem: wdrożenie", status: .interrupted, appName: "Meet")
        meeting.interruptions = [1212]
        let lines: [SampleLine] = [
            (5, 14, .me, nil, "Dzień dobry, dziękuję za czas. Chciałbym omówić plan wdrożenia na listopad."),
            (15.5, 27, .them, nil, "Dzień dobry. Najważniejsze jest dla nas szkolenie zespołu przed startem."),
            (600, 610, .me, nil, "Proponuję dwa krótkie szkolenia online i jedno spotkanie na miejscu."),
            (611, 622, .them, nil, "Brzmi dobrze. Potrzebujemy też dostępu testowego dla pięciu osób."),
            (1840, 1850, .me, nil, "Wracam, połączenie na chwilę się zerwało. Na czym skończyliśmy?"),
            (1851, 1860, .them, nil, "Na dostępach testowych. Prześlę listę osób do piątku."),
        ]
        return (meeting, segments(meeting.id, lines))
    }

    /// `CAPTYLO_PREVIEW_LIVE`: an invented Meet call recording right now, 12:34 in, with a few
    /// finished lines, one grey line of the other side still being transcribed and two notes
    /// typed so far. Newer than every sample meeting, so the preview opens on it.
    static func sampleLiveMeeting(now: Date) -> (meeting: MeetingRecord, segments: [MeetingSegmentRecord], partials: [MeetingTrack: String], elapsed: TimeInterval) {
        let elapsed: TimeInterval = 754
        let createdAt = now.addingTimeInterval(-elapsed)
        var meeting = MeetingRecord(
            createdAt: createdAt,
            title: MeetingRecorder.defaultTitle(appName: "Meet", date: createdAt),
            status: .recording,
            appName: "Meet"
        )
        meeting.noteLines = [
            MeetingNoteLine(text: "demo w piątek", at: 20),
            MeetingNoteLine(text: "dostęp do panelu: 2 osoby, zaproszenia dziś", at: 615),
        ]
        meeting.notes = meeting.noteLines.map(\.text).joined(separator: "\n")
        let lines: [SampleLine] = [
            (3, 8, .me, nil, "Dzień dobry, słychać mnie dobrze?"),
            (8.5, 14, .them, nil, "Tak, wszystko gra. Zaczynamy od harmonogramu wdrożenia?"),
            (15, 24, .me, nil, "Tak. Wersję demo pokażemy w piątek, a wdrożenie zaczniemy od poniedziałku."),
            (602, 612, .them, nil, "Piątek nam pasuje. Potrzebujemy jeszcze dostępu do panelu dla dwóch osób."),
            (613, 618, .me, nil, "Jasne, wyślę zaproszenia dziś po południu."),
            (700, 712, .them, nil, "Zostaje szkolenie, bo część zespołu pierwszy raz pracuje z takim narzędziem."),
            (714, 722, .me, nil, "Możemy zrobić je online, w dwóch krótkich turach."),
        ]
        let partials: [MeetingTrack: String] = [.them: "Dwie tury pasują, najlepiej rano, bo po południu mamy"]
        return (meeting, segments(meeting.id, lines), partials, elapsed)
    }
}

/// Deterministic SplitMix64 so every preview run shows the same history.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

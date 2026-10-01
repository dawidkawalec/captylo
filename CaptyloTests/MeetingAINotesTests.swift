import Foundation
import Testing
@testable import Captylo

struct MeetingAINotesTests {
    // MARK: Citations

    @Test func citationsReadMinutesAndHours() {
        let found = MeetingCitations.split("Budżet [1:05], wideo [1:02:03] i [0:07], koniec [62:03]")
        #expect(found.citations == [65, 3723, 7, 3723])
    }

    @Test func onlyRealClockStampsAreCitations() {
        for text in ["[1:75]", "[a:05]", "1:05", "[1:5]", "[1:61:00]", "[123:05]", "[ 1:05 ]", "[1:05:7]"] {
            let line = MeetingCitations.split(text)
            #expect(line.citations.isEmpty, "\(text)")
            #expect(line.text == text)
        }
    }

    @Test func strippingACitationKeepsTheSentence() {
        let end = MeetingCitations.split("Wyniki porównamy 15 października [1:58]")
        #expect(end.text == "Wyniki porównamy 15 października")
        #expect(end.citations == [118])

        let middle = MeetingCitations.split("Spotkanie [1:58], potem [2:10] reszta.")
        #expect(middle.text == "Spotkanie, potem reszta.")
        #expect(middle.citations == [118, 130])

        let start = MeetingCitations.split("[0:12] Na start")
        #expect(start.text == "Na start")
        #expect(start.citations == [12])

        let together = MeetingCitations.split("Dwa źródła [0:12] [0:25]")
        #expect(together.text == "Dwa źródła")
        #expect(together.citations == [12, 25])

        let plain = MeetingCitations.split("Bez cytatu, **pogrubione**")
        #expect(plain.text == "Bez cytatu, **pogrubione**")
        #expect(plain.citations.isEmpty)
    }

    @Test func aCitationPlaysTheTrackSpokenThen() {
        let id = UUID()
        let segments = [
            MeetingSegmentRecord(meetingID: id, track: .me, start: 4, end: 11, text: "a"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 12.5, end: 24, text: "b"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 14, end: 16, text: "b", isEcho: true),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 30, end: 40, text: "c"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 35, end: 38, text: "d"),
        ]
        // "[0:12]" cites the line that starts at 12.5 s (stamps drop the fraction).
        #expect(MeetingCitations.track(at: 12, in: segments) == .them)
        #expect(MeetingCitations.track(at: 5, in: segments) == .me)
        // The echo of the other side on the mic is never the source.
        #expect(MeetingCitations.track(at: 15, in: segments) == .them)
        // Overlapping lines: the one that starts at the cited second.
        #expect(MeetingCitations.track(at: 35, in: segments) == .them)
        #expect(MeetingCitations.track(at: 31, in: segments) == .me)
        // Between lines or past the end: the nearest one.
        #expect(MeetingCitations.track(at: 26, in: segments) == .them)
        #expect(MeetingCitations.track(at: 5000, in: segments) == .me)
        #expect(MeetingCitations.track(at: 12, in: []) == nil)
    }

    // MARK: Document

    private let sample = """
    ## Podsumowanie
    - We wrześniu wydaliśmy 32 tys. zł [0:12]
    - **Koszt leada** jest wysoki [0:25]

    ## Decyzje
    - Test LinkedIn do 5 tys. zł [1:45]

    ## Zadania:
    - Anna: przygotować budżet do piątku [1:05]
    * Ja: napisać do klienta [2:00]
    - [x] Mówca 2: wysłać liczby [45:00]

    ## Otwarte pytania
    - Czy agencja zdąży? [22:00]
    Zostało to bez odpowiedzi.
    """

    @Test func notesSplitIntoSectionsWithRows() {
        let document = MeetingNotesDocument(markdown: sample)
        #expect(document.sections.map(\.title) == ["Podsumowanie", "Decyzje", "Zadania", "Otwarte pytania"])
        #expect(document.sections[0].items == [
            .bullet(.init(text: "We wrześniu wydaliśmy 32 tys. zł", citations: [12])),
            .bullet(.init(text: "**Koszt leada** jest wysoki", citations: [25])),
        ])
        #expect(document.sections[3].items == [
            .bullet(.init(text: "Czy agencja zdąży?", citations: [1320])),
            .paragraph(.init(text: "Zostało to bez odpowiedzi.", citations: [])),
        ])
    }

    @Test func bulletsUnderZadaniaAreCheckableTasks() {
        let document = MeetingNotesDocument(markdown: sample)
        #expect(document.sections[2].items == [
            .task(index: 0, line: .init(text: "Anna: przygotować budżet do piątku", citations: [65]), done: false),
            .task(index: 1, line: .init(text: "Ja: napisać do klienta", citations: [120]), done: false),
            .task(index: 2, line: .init(text: "Mówca 2: wysłać liczby", citations: [2700]), done: true),
        ])
        // The same items `MeetingNotesParser` reads (the export and later features use it).
        let parsed = MeetingNotesParser.actionItems(in: sample).map { MeetingCitations.split($0).text }
        #expect(document.tasks.map(\.text) == parsed.map { $0.replacingOccurrences(of: "[x] ", with: "") })
    }

    @Test func aCheckboxBulletIsATaskAnywhere() {
        let document = MeetingNotesDocument(markdown: "## Następne kroki\n- [ ] Spotkanie z wynikami [1:58]\n- Zwykły punkt")
        #expect(document.sections[0].items == [
            .task(index: 0, line: .init(text: "Spotkanie z wynikami", citations: [118]), done: false),
            .bullet(.init(text: "Zwykły punkt", citations: [])),
        ])
    }

    @Test func textBeforeTheFirstHeadingHasNoTitle() {
        let document = MeetingNotesDocument(markdown: "Krótkie spotkanie.\n\n### Decyzje\n\n# \n- Tak [0:05]")
        #expect(document.sections.map(\.title) == [nil, "Decyzje"])
        #expect(document.sections[0].items == [.paragraph(.init(text: "Krótkie spotkanie.", citations: []))])
        #expect(document.sections[1].items == [.bullet(.init(text: "Tak", citations: [5]))])
        #expect(MeetingNotesDocument(markdown: "  \n\n").sections.isEmpty)
    }

    @MainActor
    @Test func sampleMeetingNotesReadAsFiveSections() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z"))
        let summary = try #require(DesignPreviewData.sampleMeetings(now: now).first?.meeting.summary)
        let document = MeetingNotesDocument(markdown: summary)
        #expect(document.sections.map(\.title) == ["Podsumowanie", "Decyzje", "Zadania", "Otwarte pytania", "Następne kroki"])
        #expect(document.tasks.count == MeetingNotesParser.actionItems(in: summary).count)
        #expect(document.sections.allSatisfy { section in
            section.items.allSatisfy { !$0.line.citations.isEmpty && !$0.line.text.contains("[") }
        })
    }

    // MARK: Runs

    @MainActor
    @Test func aRunShowsUntilItsNotesAreWritten() async throws {
        let gate = RunGate()
        let runs = MeetingNotesRuns { id, templateID in
            await gate.pass(id, templateID)
        }
        let id = UUID()
        let other = UUID()
        let task = try #require(runs.regenerate(meetingID: id, templateID: "standup"))
        #expect(runs.isRunning(id))
        #expect(!runs.isRunning(other))
        // A second click while it runs starts nothing.
        #expect(runs.regenerate(meetingID: id, templateID: "general") == nil)

        await gate.open()
        await task.value
        #expect(!runs.isRunning(id))
        #expect(runs.finishedCount == 1)
        let calls = await gate.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == id)
        #expect(calls.first?.templateID == "standup")

        // Done: the next click runs again.
        let again = try #require(runs.regenerate(meetingID: id, templateID: nil))
        await again.value
        #expect(runs.finishedCount == 2)
        #expect(await gate.calls.last?.templateID == nil)
    }
}

/// Holds every run until `open()`, and records what each run was asked for.
private actor RunGate {
    struct Call: Sendable {
        let id: UUID
        let templateID: String?
    }

    private(set) var calls: [Call] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass(_ id: UUID, _ templateID: String?) async {
        calls.append(Call(id: id, templateID: templateID))
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}

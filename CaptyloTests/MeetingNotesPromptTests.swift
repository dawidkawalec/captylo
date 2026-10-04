import Foundation
import Testing
@testable import Captylo

struct MeetingNotesPromptTests {
    @Test func templatePickUsesTitleKeywords() {
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Daily standup zespołu").id == "standup")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "1:1 z Anną").id == "oneOnOne")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Rozmowa rekrutacyjna - frontend").id == "interview")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Demo dla klienta").id == "client")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Wykład: prawo pracy").id == "lecture")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Spotkanie w Zoom, 30 września").id == "general")
        #expect(BuiltInMeetingTemplates.template(id: "nope").id == "general")
        #expect(BuiltInMeetingTemplates.template(id: nil).id == "general")
        #expect(BuiltInMeetingTemplates.template(id: "client").id == "client")
    }

    /// Default titles end with the start time: "11:15" or "1:10 PM" must not read as a 1:1.
    @Test func clockTimesInDefaultTitlesDoNotPickOneOnOne() {
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Spotkanie w Zoom, 30 września 11:15").id == "general")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Spotkanie, 1 października 21:10").id == "general")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Meeting, October 1 1:10 PM").id == "general")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Spotkanie 1:1, 30 września 11:15").id == "oneOnOne")
    }

    /// The ids are the relay's template ids: a new one needs its instructions on the server.
    @Test func everyTemplateHasAUniqueIDAndName() {
        let ids = BuiltInMeetingTemplates.all.map(\.id)
        #expect(ids == ["general", "oneOnOne", "standup", "client", "interview", "lecture"])
        #expect(Set(ids).count == ids.count)
        #expect(BuiltInMeetingTemplates.all.allSatisfy { !$0.name.isEmpty })
    }

    @Test func userMessageCarriesNotesTranscriptLabelsAndStamps() {
        let id = UUID()
        var meeting = MeetingRecord(id: id, title: "Budżet Q4")
        meeting.noteLines = [MeetingNoteLine(text: "budżet reklam", at: 65), MeetingNoteLine(text: "  ", at: 70)]
        meeting.speakerNames = ["1": "Anna"]
        let segments = [
            MeetingSegmentRecord(meetingID: id, track: .them, start: 65, end: 70, text: "Dwadzieścia tysięcy.", speaker: "1"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 61, end: 64, text: "Ile mamy na reklamy?"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 66, end: 69, text: "echo", isEcho: true),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 72, end: 74, text: "A ile na targi?", speaker: "2"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 3_725, end: 3_727, text: "Do zobaczenia."),
        ]
        let user = MeetingNotesPrompt.user(meeting: meeting, segments: segments)
        #expect(user.contains("Tytuł: Budżet Q4"))
        #expect(user.contains("<user_notes>\n[1:05] budżet reklam\n</user_notes>"))
        #expect(user.contains("<transcript>\n[1:01] Ja: Ile mamy na reklamy?\n[1:05] Anna: Dwadzieścia tysięcy."))
        #expect(user.contains("[1:12] Mówca 2: A ile na targi?"))
        #expect(user.contains("[1:02:05] Rozmówcy: Do zobaczenia.\n</transcript>"))
        #expect(!user.contains("echo"))
    }

    /// The participants from the calendar go after the title, so the notes spell the names
    /// right; a meeting without them has no such line.
    @Test func userMessageListsTheParticipantsAfterTheTitle() {
        let id = UUID()
        var meeting = MeetingRecord(id: id, title: "Budżet Q4")
        meeting.participants = ["Anna Kowalska", "Piotr Nowak"]
        let segments = [MeetingSegmentRecord(meetingID: id, track: .me, start: 1, end: 2, text: "Zaczynamy.")]
        let user = MeetingNotesPrompt.user(meeting: meeting, segments: segments)
        #expect(user.hasPrefix("Tytuł: Budżet Q4\nUczestnicy: Anna Kowalska, Piotr Nowak\n<user_notes>"))

        meeting.participants = []
        let alone = MeetingNotesPrompt.user(meeting: meeting, segments: segments)
        #expect(alone.hasPrefix("Tytuł: Budżet Q4\n<user_notes>"))
        #expect(!alone.contains("Uczestnicy"))
    }

    /// The prompt is Polish whatever the UI language: labels never go through the string catalog.
    @Test func promptLabelsDoNotDependOnTheUILanguage() {
        let id = UUID()
        var meeting = MeetingRecord(id: id, title: "x")
        meeting.speakerNames = ["1": "Anna", "3": ""]
        #expect(meeting.promptLabel(for: MeetingSegmentRecord(meetingID: id, track: .me, start: 0, end: 1, text: "a")) == "Ja")
        #expect(meeting.promptLabel(for: MeetingSegmentRecord(meetingID: id, track: .them, start: 0, end: 1, text: "a")) == "Rozmówcy")
        #expect(meeting.promptLabel(for: MeetingSegmentRecord(meetingID: id, track: .them, start: 0, end: 1, text: "a", speaker: "1")) == "Anna")
        #expect(meeting.promptLabel(for: MeetingSegmentRecord(meetingID: id, track: .them, start: 0, end: 1, text: "a", speaker: "3")) == "Mówca 3")
    }

    @Test func actionItemsAreTheBulletsUnderZadania() {
        let markdown = """
        ## Podsumowanie
        - coś [0:10]
        ## Zadania
        - Anna: przygotować budżet do piątku [1:05]
        * Dawid: napisać do klienta [2:00]

        ## Otwarte pytania
        - czy robimy kampanię?
        """
        #expect(MeetingNotesParser.actionItems(in: markdown) == ["Anna: przygotować budżet do piątku [1:05]", "Dawid: napisać do klienta [2:00]"])
        #expect(MeetingNotesParser.actionItems(in: "## Podsumowanie\n- x").isEmpty)
        #expect(MeetingNotesParser.actionItems(in: "## Zadania:\n- Ja: wysłać ofertę [0:30]") == ["Ja: wysłać ofertę [0:30]"])
    }
}

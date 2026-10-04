import Foundation
import Testing
@testable import Captylo

@MainActor
struct MeetingProAccessTests {
    private func settings() -> AppSettings {
        let name = "meeting-pro-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults)
    }

    private func account(_ state: AccountStore.State, settings: AppSettings) -> AccountStore {
        AccountStore(
            client: AccountClient(baseURL: AccountClient.defaultBaseURL, session: StubURLProtocol.makeSession()),
            keyStore: .inMemory(),
            settings: settings,
            pinned: state
        )
    }

    @Test func freeByDefault() {
        let access = ProAccess(settings: settings(), account: nil, environment: [:])
        #expect(access.isPro == false)
        #expect(access.allows(.meetingAINotes) == false)
    }

    @Test func devSwitchUnlocksPro() {
        let s = settings()
        s.devPro = true
        #expect(ProAccess(settings: s, account: nil, environment: [:]).isPro)
    }

    @Test func environmentUnlocksPro() {
        #expect(ProAccess(settings: settings(), account: nil, environment: ["CAPTYLO_DEV_PRO": "1"]).isPro)
        #expect(ProAccess(settings: settings(), account: nil, environment: ["CAPTYLO_DEV_PRO": "0"]).isPro == false)
    }

    @Test func pinnedWins() {
        let s = settings()
        s.devPro = true
        #expect(ProAccess(settings: s, account: nil, pinned: false, environment: [:]).isPro == false)
    }

    @Test func aSignedInProAccountIsPro() throws {
        let s = settings()
        let pro = account(.signedIn(try AccountFixtures.proInfo()), settings: s)
        let access = ProAccess(settings: s, account: pro, environment: [:])
        #expect(access.isPro)
        #expect(access.allows(.cloudMeetingTranscription))
    }

    @Test func aFreeOrSignedOutAccountIsNotPro() throws {
        let s = settings()
        let free = account(.signedIn(try AccountFixtures.freeInfo()), settings: s)
        #expect(ProAccess(settings: s, account: free, environment: [:]).isPro == false)
        let signedOut = account(.signedOut, settings: s)
        #expect(ProAccess(settings: s, account: signedOut, environment: [:]).isPro == false)
        let waiting = account(.codeSent(email: "anna@example.com"), settings: s)
        #expect(ProAccess(settings: s, account: waiting, environment: [:]).isPro == false)
    }

    @Test func retentionDays() {
        #expect(MeetingAudioRetention.none.days == 0)
        #expect(MeetingAudioRetention.days7.days == 7)
        #expect(MeetingAudioRetention.days30.days == 30)
        #expect(MeetingAudioRetention.forever.days == nil)
    }

    @Test func meetingSettingsDefaultsAndPersist() {
        let s = settings()
        #expect(s.devPro == false)
        #expect(s.meetingsAutoDetect)
        #expect(s.meetingsConsentReminder)
        #expect(s.meetingAudioRetention == .days7)

        s.meetingAudioRetention = .forever
        s.meetingsAutoDetect = false
        #expect(s.meetingAudioRetention == .forever)
        #expect(s.meetingsAutoDetect == false)

        s.reset()
        #expect(s.meetingAudioRetention == .days7)
        #expect(s.meetingsAutoDetect)
    }

    @Test func trackFilesLiveInTheirOwnMeetingFolder() {
        let id = UUID()
        #expect(AppPaths.meetings.lastPathComponent == "Meetings")
        #expect(AppPaths.meetings.deletingLastPathComponent().standardizedFileURL == AppPaths.dataDirectory.standardizedFileURL)
        #expect(AppPaths.meetingFolder(id).lastPathComponent == id.uuidString)
        #expect(AppPaths.meetingTrackURL(id, track: .me).lastPathComponent == "me.caf")
        #expect(AppPaths.meetingTrackURL(id, track: .them).lastPathComponent == "them.caf")
        #expect(AppPaths.meetingTrackURL(id, track: .them).deletingLastPathComponent() == AppPaths.meetingFolder(id))
        #expect(!AppPaths.meetingTrackURL(id, track: .me).path(percentEncoded: false).contains("/Recordings/"))
    }

    @Test func segmentLabelPrefersNameThenSpeakerThenTrack() {
        let meeting = MeetingRecord(title: "Spotkanie", speakerNames: ["1": "Anna", "3": ""])
        let mine = MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 1, text: "Cześć")
        let named = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 1, end: 2, text: "Hej", speaker: "1")
        let unnamed = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 2, end: 3, text: "Tak", speaker: "2")
        let blankName = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 3, end: 4, text: "Nie", speaker: "3")
        let others = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 4, end: 5, text: "Dobra")

        #expect(meeting.label(for: mine) == MeetingTrack.me.defaultLabel)
        #expect(meeting.label(for: named) == "Anna")
        #expect(meeting.label(for: unnamed) == String(localized: "Mówca \("2")"))
        #expect(meeting.label(for: blankName) == String(localized: "Mówca \("3")"))
        #expect(meeting.label(for: others) == MeetingTrack.them.defaultLabel)
        #expect(MeetingTrack.me.fileName == "me.caf")
        #expect(MeetingTrack.them.fileName == "them.caf")
    }
}

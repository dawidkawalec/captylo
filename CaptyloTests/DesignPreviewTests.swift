import Foundation
import Testing
@testable import Captylo

@MainActor
struct DesignPreviewTests {
    @Test func targetsMatchTheDocumentedList() {
        let expected = [
            "widget-compact", "widget-compact-mode", "widget-expanded", "widget-transcribing", "widget-enhancing",
            "onboarding-welcome", "onboarding-permissions", "onboarding-model", "onboarding-shortcut", "onboarding-tryit",
            "main-pulpit", "main-spotkania", "main-historia", "main-plik", "main-slownik", "main-modele", "main-ustawienia",
            "glass-gallery",
        ]
        #expect(DesignPreviewTarget.allCases.map(\.rawValue) == expected)
    }

    @Test func targetsMapToScreens() {
        #expect(DesignPreviewTarget.widgetExpanded.kind == .widget(expanded: true, state: .recording))
        #expect(DesignPreviewTarget.widgetTranscribing.kind == .widget(expanded: false, state: .transcribing))
        #expect(DesignPreviewTarget.widgetEnhancing.kind == .widget(expanded: false, state: .enhancing))
        #expect(DesignPreviewTarget.onboardingTryIt.kind == .onboarding(.tryIt))
        #expect(DesignPreviewTarget.mainSlownik.kind == .main(.slownik))
        #expect(DesignPreviewTarget.mainSpotkania.kind == .main(.spotkania))
        #expect(DesignPreviewTarget.glassGallery.kind == .gallery)
        #expect(DesignPreviewTarget.widgetCompact.isWidget)
        #expect(!DesignPreviewTarget.mainPulpit.isWidget)
    }

    @Test func everyOnboardingStepAndSectionHasATarget() {
        let steps = DesignPreviewTarget.allCases.compactMap { target -> OnboardingStep? in
            if case .onboarding(let step) = target.kind { return step }
            return nil
        }
        let sections = DesignPreviewTarget.allCases.compactMap { target -> MainSection? in
            if case .main(let section) = target.kind { return section }
            return nil
        }
        #expect(steps == OnboardingStep.allCases)
        #expect(sections == MainSection.allCases)
    }

    @Test func sampleHistorySpansTwoWeeks() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z"))
        let calendar = Calendar(identifier: .gregorian)
        let records = DesignPreviewData.sampleRecords(now: now, calendar: calendar)
        #expect(records.count == DesignPreviewData.dictationCount)
        #expect(Set(records.map(\.id)).count == records.count)

        let oldest = try #require(records.map(\.createdAt).min())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: oldest), to: calendar.startOfDay(for: now)).day ?? 0
        #expect(days <= DesignPreviewData.dayRange - 1)
        #expect(records.allSatisfy { $0.createdAt <= now })
        #expect(records.allSatisfy { $0.wordCount > 0 && $0.audioDuration > 0 && !$0.text.isEmpty })
        #expect(records.contains { $0.enhancedText != nil })
        #expect(records.contains { $0.source == .file })
        // Historia shows AI versions in several modes, notes, and rows dictated without AI.
        #expect(Set(records.compactMap(\.enhancementMode)).count >= 4)
        #expect(records.contains { $0.enhancementNote != nil && $0.enhancedText == nil })
        #expect(records.contains { $0.enhancementMode == nil })
        #expect(records.allSatisfy { $0.enhancementNote == nil || $0.enhancementMode != nil })
        #expect(records.allSatisfy { $0.wordCount == WordCounter.count($0.finalText) })
    }

    @Test func sampleMeetingsShowEveryState() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z"))
        let meetings = DesignPreviewData.sampleMeetings(now: now)
        #expect(meetings.count == 3)
        #expect(Set(meetings.map(\.meeting.id)).count == 3)
        let dates = meetings.map(\.meeting.createdAt)
        #expect(dates == dates.sorted(by: >), "newest first, the preview selects the first one")

        let newest = try #require(meetings.first)
        let summary = try #require(newest.meeting.summary)
        for heading in ["Podsumowanie", "Decyzje", "Zadania", "Otwarte pytania", "Następne kroki"] {
            #expect(summary.contains("## \(heading)"))
        }
        #expect(!MeetingNotesParser.actionItems(in: summary).isEmpty)
        #expect(!newest.meeting.speakerNames.isEmpty)
        #expect(!newest.meeting.noteLines.isEmpty)
        #expect(newest.segments.count == 12)
        #expect(newest.segments.contains { $0.speaker != nil && newest.meeting.speakerNames[$0.speaker ?? ""] == nil })

        #expect(meetings.contains { $0.meeting.summary == nil && $0.meeting.status == .completed })
        let interrupted = try #require(meetings.first { $0.meeting.status == .interrupted })
        #expect(interrupted.segments.count == 6)
        #expect(!interrupted.meeting.interruptions.isEmpty)

        // Like a real quit mid-meeting, the interrupted one never stored its length.
        #expect(interrupted.meeting.duration == 0)

        for (meeting, segments) in meetings {
            #expect(meeting.createdAt <= now)
            let length = meeting.duration > 0 ? meeting.duration : (segments.map(\.end).max() ?? 0)
            #expect(length > 0)
            #expect(segments.allSatisfy { $0.meetingID == meeting.id })
            #expect(segments.allSatisfy { $0.start < $0.end && $0.end - $0.start <= 14 && $0.end <= length })
            #expect(segments.contains { $0.track == .me } && segments.contains { $0.track == .them })
            #expect(meeting.noteLines.allSatisfy { $0.at <= length })
        }
    }

    /// `CAPTYLO_PREVIEW_LIVE=1`: a meeting recording right now, newer than every sample meeting,
    /// so the preview opens on it.
    @Test func sampleLiveMeetingIsRecordingNow() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z"))
        let live = DesignPreviewData.sampleLiveMeeting(now: now)
        #expect(live.meeting.status == .recording)
        #expect(live.meeting.createdAt == now.addingTimeInterval(-live.elapsed))
        let newestSample = try #require(DesignPreviewData.sampleMeetings(now: now).first)
        #expect(live.meeting.createdAt > newestSample.meeting.createdAt)
        #expect(!live.segments.isEmpty)
        #expect(live.segments.allSatisfy { $0.meetingID == live.meeting.id && $0.start < $0.end && $0.end <= live.elapsed })
        #expect(live.segments.map(\.start) == live.segments.map(\.start).sorted())
        #expect(live.segments.contains { $0.track == .me } && live.segments.contains { $0.track == .them })
        #expect(!live.partials.isEmpty)
        #expect(!live.meeting.noteLines.isEmpty)
        #expect(live.meeting.noteLines.allSatisfy { $0.at <= live.elapsed })
        #expect(live.meeting.notes == live.meeting.noteLines.map(\.text).joined(separator: "\n"))
    }

    /// `CAPTYLO_PREVIEW_TAB` and `CAPTYLO_PREVIEW_FREE` (the "Notatki AI" tab, Pro and Free).
    @Test func previewPicksTheMeetingTabAndPlan() {
        #expect(DesignPreviewData.meetingTab(environment: ["CAPTYLO_PREVIEW_TAB": "ai"]) == .aiNotes)
        #expect(DesignPreviewData.meetingTab(environment: ["CAPTYLO_PREVIEW_TAB": "Notes"]) == .notes)
        #expect(DesignPreviewData.meetingTab(environment: ["CAPTYLO_PREVIEW_TAB": "transcript"]) == .transcript)
        #expect(DesignPreviewData.meetingTab(environment: ["CAPTYLO_PREVIEW_TAB": "x"]) == nil)
        #expect(DesignPreviewData.meetingTab(environment: [:]) == nil)
        #expect(DesignPreviewData.showsFreePlan(environment: ["CAPTYLO_PREVIEW_FREE": "1"]))
        #expect(!DesignPreviewData.showsFreePlan(environment: ["CAPTYLO_PREVIEW_FREE": "0"]))
        #expect(!DesignPreviewData.showsFreePlan(environment: [:]))
        #expect(DesignPreviewData.editsMeetingTitle(environment: ["CAPTYLO_PREVIEW_TITLE_EDIT": "1"]))
        #expect(!DesignPreviewData.editsMeetingTitle(environment: [:]))
    }

    /// `CAPTYLO_PREVIEW_AUDIO_CHECK`: the result the system audio check row in Ustawienia shows.
    @Test func previewPicksTheSystemAudioCheckResult() {
        #expect(DesignPreviewData.audioCheckOutcome(environment: ["CAPTYLO_PREVIEW_AUDIO_CHECK": "works"]) == .works)
        #expect(DesignPreviewData.audioCheckOutcome(environment: ["CAPTYLO_PREVIEW_AUDIO_CHECK": "NoAccess"]) == .noAccess)
        #expect(DesignPreviewData.audioCheckOutcome(environment: ["CAPTYLO_PREVIEW_AUDIO_CHECK": "nothing"]) == .nothingPlaying)
        if case .failed(let message)? = DesignPreviewData.audioCheckOutcome(environment: ["CAPTYLO_PREVIEW_AUDIO_CHECK": "failed"]) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected a failed outcome")
        }
        #expect(DesignPreviewData.audioCheckOutcome(environment: ["CAPTYLO_PREVIEW_AUDIO_CHECK": "x"]) == nil)
        #expect(DesignPreviewData.audioCheckOutcome(environment: [:]) == nil)
    }

    /// `CAPTYLO_PREVIEW_SCROLL`: how far down a long page opens (0 top, 1 bottom), clamped.
    @Test func previewScrollsLongPages() {
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "0.4"]) == 0.4)
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "1"]) == 1)
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "7"]) == 1)
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "-1"]) == 0)
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "x"]) == nil)
        #expect(DesignPreviewData.scrollFraction(environment: ["CAPTYLO_PREVIEW_SCROLL": "nan"]) == nil)
        #expect(DesignPreviewData.scrollFraction(environment: [:]) == nil)
    }

    /// `CAPTYLO_PREVIEW_CALENDAR=1`: three invented events in the next hours, soonest first, at
    /// least one with a call link and one without, so the strip shows both looks.
    @Test func previewShowsAnInventedCalendar() {
        #expect(DesignPreviewData.showsCalendar(environment: ["CAPTYLO_PREVIEW_CALENDAR": "1"]))
        #expect(!DesignPreviewData.showsCalendar(environment: ["CAPTYLO_PREVIEW_CALENDAR": "0"]))
        #expect(!DesignPreviewData.showsCalendar(environment: [:]))

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let events = DesignPreviewData.sampleCalendarEvents(now: now)
        #expect(events.count == 3)
        #expect(events == events.sorted { $0.start < $1.start })
        #expect(events.allSatisfy { $0.start > now && $0.end > $0.start && !$0.isAllDay && !$0.title.isEmpty })
        #expect(events.allSatisfy { $0.end.timeIntervalSince(now) < MeetingCalendar.lookAhead })
        #expect(events.contains { $0.hasCallLink } && events.contains { !$0.hasCallLink })
        #expect(Set(events.map(\.id)).count == 3)
        #expect(UpcomingMeetingsStrip.visible(events, now: now).count == 3)
    }

    @Test func sampleCustomModeIsTheUsersOwn() {
        let mode = DesignPreviewData.sampleCustomMode
        #expect(mode.builtInKey == nil)
        #expect(mode.kind == .rewrite)
        #expect(mode.prompt.contains(CleanupPrompt.dictionaryPlaceholder))
        #expect(!BuiltInAIModes.all.map(\.id).contains(mode.id))
    }

    @Test func sampleHistoryIsDeterministic() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z"))
        let first = DesignPreviewData.sampleRecords(now: now).map { [$0.text, "\($0.createdAt)", "\($0.audioDuration)"] }
        let second = DesignPreviewData.sampleRecords(now: now).map { [$0.text, "\($0.createdAt)", "\($0.audioDuration)"] }
        #expect(first == second)
    }

    @Test func openRouterFixtureHoldsTheQuickPicks() {
        let ids = Set(DesignPreviewData.openRouterModels.map(\.id))
        #expect(OpenRouterModel.quickPickIDs.allSatisfy { ids.contains($0) })
        #expect(ids.contains("openai/gpt-4.1-mini"))
    }

    @Test func pinnedModelStatusSurvivesRefresh() {
        let store = ParakeetModelStore(engine: ParakeetEngine(), pinnedStatus: .ready)
        store.refresh()
        #expect(store.status == .ready)
    }

    @Test func pinnedAccessibilityTrustSurvivesRefresh() {
        let watcher = AccessibilityWatcher(pinnedTrust: true)
        watcher.refresh()
        #expect(watcher.isTrusted)
    }
}

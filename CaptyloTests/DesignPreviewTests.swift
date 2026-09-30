import Foundation
import Testing
@testable import Captylo

@MainActor
struct DesignPreviewTests {
    @Test func targetsMatchTheDocumentedList() {
        let expected = [
            "widget-compact", "widget-compact-mode", "widget-expanded", "widget-transcribing", "widget-enhancing",
            "onboarding-welcome", "onboarding-permissions", "onboarding-model", "onboarding-shortcut", "onboarding-tryit",
            "main-pulpit", "main-historia", "main-plik", "main-slownik", "main-modele", "main-ustawienia",
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

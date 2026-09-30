import Foundation
import Testing
@testable import Captylo

/// The onboarding must never trap the user: "Zakończ" on the last step and "Pomiń wprowadzenie"
/// on a middle step both finish the flow and ask the presenter to close the window. Runs on the
/// design-preview `AppState` (throwaway defaults suite, no services), never the real domain.
@MainActor
struct OnboardingModelTests {
    private func makeModel(at step: OnboardingStep) -> (OnboardingModel, AppSettings) {
        let appState = DesignPreviewData.makeAppState()
        let settings = appState.settings
        settings.onboardingDone = false
        settings.onboardingStep = step.rawValue
        return (OnboardingModel(appState: appState), settings)
    }

    @Test func finishOnTheLastStepClosesTheWindow() {
        let (model, settings) = makeModel(at: .tryIt)
        var closed = 0
        model.onFinished = { closed += 1 }

        #expect(model.step == .tryIt)
        #expect(model.canAdvance)
        #expect(model.primaryTitle == String(localized: "Zakończ"))

        model.advance()

        #expect(closed == 1)
        #expect(settings.onboardingDone)
        #expect(settings.onboardingStep == AppSettings.defaultOnboardingStep)
    }

    @Test func everyStepCanAdvanceToTheEnd() {
        let (model, settings) = makeModel(at: .welcome)
        var closed = false
        model.onFinished = { closed = true }

        for _ in OnboardingStep.allCases {
            #expect(model.canAdvance)
            model.advance()
        }

        #expect(closed)
        #expect(settings.onboardingDone)
    }

    @Test func skipFinishesFromAMiddleStep() {
        let (model, settings) = makeModel(at: .permissions)
        var closed = false
        model.onFinished = { closed = true }

        #expect(model.canSkip)
        model.skip()

        #expect(closed)
        #expect(settings.onboardingDone)
    }
}

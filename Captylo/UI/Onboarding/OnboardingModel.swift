import Foundation
import Observation

/// Navigation state of the onboarding window: the current step (mirrored into
/// `AppSettings.onboardingStep` on every change) and the finish / skip actions.
@MainActor
@Observable
final class OnboardingModel {
    let appState: AppState
    private(set) var step: OnboardingStep

    /// Called once after `finish()` stored the completion; the presenter closes the window.
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?

    init(appState: AppState) {
        self.appState = appState
        step = OnboardingStep(persisted: appState.settings.onboardingStep)
    }

    var settings: AppSettings { appState.settings }

    var canGoBack: Bool { !step.isFirst }

    /// "Pomiń wprowadzenie" (ends the whole flow) is offered on the middle steps only: the welcome
    /// screen has nothing to skip and the last step finishes the flow anyway.
    var canSkip: Bool { !step.isFirst && !step.isLast }

    /// The primary button never blocks: a running model download continues in
    /// `LocalModelStore`, and the Wypróbuj step shows its progress.
    var canAdvance: Bool { true }

    var primaryTitle: String {
        step.isLast ? String(localized: "Zakończ") : String(localized: "Dalej")
    }

    // MARK: Navigation

    func advance() {
        guard canAdvance else { return }
        if let next = step.next {
            go(to: next)
        } else {
            finish()
        }
    }

    func goBack() {
        guard let previous = step.previous else { return }
        go(to: previous)
    }

    /// Jumps straight to `target` (the Wypróbuj step sends the user back to Model).
    func show(_ target: OnboardingStep) {
        guard target != step else { return }
        go(to: target)
    }

    func skip() {
        Log.ui.info("Onboarding skipped on step \(self.step.rawValue, privacy: .public)")
        finish()
    }

    /// Marks the onboarding done, resets the step for a later re-run and installs the hotkey tap
    /// when Accessibility is already trusted (otherwise `AccessibilityWatcher.onGranted` does it).
    func finish() {
        settings.onboardingDone = true
        settings.onboardingStep = AppSettings.defaultOnboardingStep
        if appState.accessibility.isTrusted, !appState.isDesignPreview {
            appState.hotkeyTap.install()
        }
        Log.ui.info("Onboarding finished")
        onFinished?()
    }

    private func go(to next: OnboardingStep) {
        step = next
        settings.onboardingStep = next.rawValue
        Log.ui.debug("Onboarding step -> \(next.rawValue, privacy: .public)")
    }
}

import SwiftUI

/// "Polski | English" at the foot of the welcome screen: someone on a Mac in the other language
/// switches before the setup. The choice is saved (`AppLanguage`) and the app relaunches on the
/// same welcome screen in that language; Ustawienia > Aplikacja changes it later.
@MainActor
struct OnboardingLanguageSwitch: View {
    let appState: AppState

    private let running = AppLanguage(rawValue: AppLanguage.runningCode) ?? .english

    var body: some View {
        GlassSegmentedPicker(
            selection: Binding(
                get: { running },
                set: { choose($0) }
            ),
            segments: [AppLanguage.polish, .english].map {
                GlassSegment($0, title: Text(verbatim: $0.title()))
            }
        )
        .accessibilityLabel(Text("Język aplikacji"))
    }

    private func choose(_ language: AppLanguage) {
        guard language != running else { return }
        AppLanguage.setPreference(AppLanguage.choice(showing: language.rawValue))
        appState.relaunchForLanguage()
    }
}

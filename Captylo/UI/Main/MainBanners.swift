import SwiftUI

/// Warnings above the screen: Accessibility missing, an old dictation app running, model missing.
/// Each one is a slim red or amber tinted glass strip with small glass action buttons.
@MainActor
struct MainBanners: View {
    @Environment(AppState.self) private var appState
    let router: MainRouter

    var body: some View {
        VStack(spacing: 8) {
            if !appState.accessibility.isTrusted {
                MainBanner(
                    symbol: "hand.raised",
                    tone: .danger,
                    text: String(localized: "Brak uprawnienia Dostępność: skrót i wklejanie nie działają.")
                ) {
                    if appState.permissions.suggestsRelaunch {
                        Button("Uruchom ponownie") {
                            appState.permissions.relaunch()
                        }
                    }
                    Button("Włącz dostęp") {
                        appState.permissions.requestAccessibility()
                    }
                }
            }
            if appState.oldAppDetector.isOldAppRunning {
                MainBanner(
                    symbol: "exclamationmark.triangle",
                    tone: .warning,
                    text: String(localized: "Uruchomiona jest stara wersja aplikacji, która używa tego samego skrótu.")
                ) {
                    Button("Zamknij starą wersję") {
                        appState.oldAppDetector.quitOldApps()
                    }
                }
            }
            switch ModelBanner(appState: appState, router: router) {
            case .missing:
                MainBanner(
                    symbol: "arrow.down.circle",
                    tone: .warning,
                    text: String(localized: "Model lokalny nie jest pobrany. Dyktowanie nie zadziała, dopóki go nie pobierzesz.")
                ) {
                    Button("Przejdź do Modele") {
                        router.select(.modele)
                    }
                }
            case .downloading(let percent):
                MainBanner(
                    symbol: "arrow.down.circle",
                    tone: .warning,
                    text: String(localized: "Pobieram model... \(percent)%")
                ) {
                    EmptyView()
                }
            case nil:
                EmptyView()
            }
        }
    }
}

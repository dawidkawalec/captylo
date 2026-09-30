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
                    text: String(localized: "Model Parakeet nie jest pobrany. Dyktowanie nie zadziała, dopóki go nie pobierzesz.")
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

/// One warning strip: tinted icon badge, the message, its actions on the right.
@MainActor
private struct MainBanner<Actions: View>: View {
    enum Tone {
        case warning
        case danger

        var color: Color {
            switch self {
            case .warning: return GlassColor.warning
            case .danger: return GlassColor.destructive
            }
        }
    }

    let symbol: String
    let tone: Tone
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            GlassIconBadge(systemImage: symbol, size: 28, tint: tone.color)
            Text(text)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                actions
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.panel, cornerRadius: GlassTokens.Radius.card, tint: tone.color.opacity(0.5))
        .accessibilityElement(children: .contain)
    }
}

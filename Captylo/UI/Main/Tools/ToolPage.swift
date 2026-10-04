import SwiftUI

/// Scrollable Dusk Glass page of the tool screens (Transkrypcja pliku, Słownik, Modele,
/// Ustawienia): transparent over the window wallpaper, an optional subtitle with trailing actions,
/// then the `GlassPanel`s. The page title comes from the shell (`MainPageHeader`), so the page never
/// draws its own; gutters, max width and the top fade match `MainGlassPage`.
@MainActor
struct ToolPage<Accessory: View, Content: View>: View {
    var subtitle: Text?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned right under the shell's page title (not inside the scroll view, where the
            // top fade pushed it about 50 pt below the title and it read as detached).
            if subtitle != nil || Accessory.self != EmptyView.self {
                header
                    .mainColumnFrame()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: MainShellMetrics.panelSpacing) {
                    content
                }
                .padding(.top, MainShellMetrics.topFade + 2)
                .padding(.bottom, 28)
                .mainColumnFrame()
            }
            .scrollContentBackground(.hidden)
            .mainEdgeFade()
        }
        .foregroundStyle(GlassColor.textPrimary)
    }

    /// Same height with or without the trailing buttons, so the subtitle baseline and the first
    /// panel do not jump between tabs. The subtitle sits on the bright sky of the wallpaper:
    /// primary white with a dark halo keeps it legible.
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            if let subtitle {
                subtitle
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
            }
            Spacer(minLength: 0)
            accessory
        }
        .frame(minHeight: GlassTokens.Size.buttonHeightSmall + 4, alignment: .center)
    }
}

extension ToolPage where Accessory == EmptyView {
    init(subtitle: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

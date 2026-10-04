import SwiftUI

/// Layout of the Dusk Glass main window: the floating sidebar, the content column gutters and the
/// readable max width shared by the page header, the banners and the pages.
enum MainShellMetrics {
    /// Width of the sidebar attached to the left window edge, the Abyss wash over its frosted
    /// glass (the lab's sidebar tint, added to the user's panel smoke from `WindowTone`) and the
    /// white hairline on its right edge.
    static let sidebarWidth: CGFloat = 228
    static let sidebarInkWash: Double = 0.2
    static let sidebarHairline: Double = 0.14
    /// Top inset of the content column below the title bar.
    static let windowInset: CGFloat = 12
    /// Horizontal gutter of the content column (room for the panel shadows inside the scroll view).
    static let gutter: CGFloat = 22
    /// Content never grows wider than this; wider windows center it.
    static let contentMaxWidth: CGFloat = 960
    /// Gap between the panels of a page.
    static let panelSpacing: CGFloat = 20
    /// Height of the soft fade where scrolled content slides under the page header.
    static let topFade: CGFloat = 14
    /// Height of the fade at the window bottom (content scrolls out below it).
    static let bottomFade: CGFloat = 24
}

extension View {
    /// Constrains a content-column block to the readable width and adds the column gutters.
    func mainColumnFrame(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: MainShellMetrics.contentMaxWidth, alignment: alignment)
            .padding(.horizontal, MainShellMetrics.gutter)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Fades content out toward the top edge of a scroll view (it slides under the page header)
    /// and toward the window bottom, so the last visible panel or row never ends in a hard cut.
    func mainEdgeFade() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: MainShellMetrics.topFade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: MainShellMetrics.bottomFade)
            }
        }
    }
}

/// Scrollable page of the Dusk Glass main window: `GlassPanel`s on the wallpaper with generous gaps,
/// no background of its own (the wallpaper of `.duskWindow()` shows through).
@MainActor
struct MainGlassPage<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = MainShellMetrics.panelSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.top, MainShellMetrics.topFade + 2)
            .padding(.bottom, 28)
            .mainColumnFrame()
        }
        .scrollContentBackground(.hidden)
        .mainEdgeFade()
    }
}

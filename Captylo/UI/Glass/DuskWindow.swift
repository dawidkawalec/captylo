import AppKit
import SwiftUI

/// `.duskWindow()`: the window chrome of every Dusk Glass window (onboarding, main window,
/// previews). Fills the window edge to edge with `DuskBackground` in the style from Ustawienia
/// ("Tło okna": the dark or light brand gradient, the living dusk lake or the aurora sky), forces
/// the dark color scheme (system controls render light-on-glass), hides the toolbar background
/// and makes the title bar transparent with the content running underneath it.
@MainActor
struct DuskWindowModifier: ViewModifier {
    var role: WindowBackdropRole
    var extendsUnderTitleBar: Bool

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: extendsUnderTitleBar ? .top : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                DuskBackground(role: role)
            }
            .background(DuskWindowConfigurator())
            .toolbarBackground(.hidden, for: .windowToolbar)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .foregroundStyle(GlassColor.textPrimary)
            .font(GlassFont.body)
            .tint(GlassColor.accent)
    }
}

extension View {
    /// Dusk Glass window (see `DuskWindowModifier`). `role` picks the scrim strength;
    /// `extendsUnderTitleBar` lets the content itself (not only the background) start at the top
    /// edge, under the traffic lights.
    func duskWindow(role: WindowBackdropRole = .window, extendsUnderTitleBar: Bool = false) -> some View {
        modifier(DuskWindowModifier(role: role, extendsUnderTitleBar: extendsUnderTitleBar))
    }
}

/// Reaches the hosting `NSWindow` once the view is in it and applies the transparent chrome.
/// Leaves `isMovableByWindowBackground` alone: when true, clicks on custom-styled SwiftUI
/// buttons start a window drag instead (the onboarding bug).
@MainActor
struct DuskWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> DuskWindowAccessorView {
        DuskWindowAccessorView()
    }

    func updateNSView(_ nsView: DuskWindowAccessorView, context: Context) {
        nsView.apply()
    }
}

/// Every background paints every pixel, so the window is opaque with a night (Ink) fill behind it.
final class DuskWindowAccessorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = NSColor(GlassColor.night)
    }
}

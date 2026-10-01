import SwiftUI

/// Main window: attached glass sidebar (Pulpit, Spotkania, Historia, Transkrypcja pliku, Słownik,
/// Modele, Ustawienia) plus the selected screen, all over the window background (`.duskWindow()`). The router
/// lives for the window's lifetime in `MainShellView`, which receives the `AppState` as a plain
/// value so it can seed `@State`; the file queue belongs to `AppState` (Finder opens reach it
/// before the window exists).
@MainActor
struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        MainShellView(appState: appState)
    }
}

@MainActor
struct MainShellView: View {
    let appState: AppState
    @State private var router: MainRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: AppState) {
        self.appState = appState
        _router = State(initialValue: MainRouter(presenter: appState.windowPresenter))
    }

    var body: some View {
        @Bindable var router = router

        // An HStack instead of NavigationSplitView: the system sidebar paints its own material and
        // divider, while Dusk Glass wants one window background with our own glass column over it.
        HStack(spacing: 0) {
            MainSidebar(selection: $router.selection)

            VStack(alignment: .leading, spacing: 0) {
                MainPageHeader(title: router.selection.title)
                MainBanners(router: router)
                    .mainColumnFrame()
                    .padding(.top, 12)
                screen(for: router.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .defaultScrollAnchor(previewScrollAnchor)
            }
            .padding(.top, MainShellMetrics.windowInset)
            .animation(reduceMotion ? nil : GlassMotion.spring, value: bannerSignature)
        }
        .navigationTitle(router.selection.title)
        .frame(minWidth: VTSize.mainWindowMin.width, minHeight: VTSize.mainWindowMin.height)
        .duskWindow()
        .environment(\.windowBackgroundStyle, appState.settings.windowBackground)
        .environment(\.windowTone, appState.settings.windowTone)
        .background(MainWindowConfigurator())
        .modelContainer(appState.modelContainer)
        .environment(router)
        .environment(appState.fileQueue)
        .onAppear {
            appState.permissions.refresh()
        }
    }

    @ViewBuilder
    private func screen(for section: MainSection) -> some View {
        switch section {
        case .pulpit: DashboardView()
        case .spotkania: MeetingsView()
        case .historia: HistoryView()
        case .plik: TranscribeFileView()
        case .slownik: DictionaryView()
        case .modele: ModelsView()
        case .ustawienia: SettingsView()
        }
    }

    /// `CAPTYLO_PREVIEW_SCROLL`: the design preview opens a long page further down; nil (the
    /// system default, the top) everywhere else.
    private var previewScrollAnchor: UnitPoint? {
        guard appState.isDesignPreview, let fraction = DesignPreviewData.scrollFraction() else { return nil }
        return UnitPoint(x: 0.5, y: fraction)
    }

    /// Which banners are up; animating on it slides the page down when one appears.
    private var bannerSignature: [Bool] {
        [
            !appState.accessibility.isTrusted,
            appState.oldAppDetector.isOldAppRunning,
            ModelBanner(appState: appState, router: router) != nil,
        ]
    }
}

/// Page title at the top left of the content column ("Pulpit"), aligned with the panels below.
@MainActor
private struct MainPageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(GlassFont.pageTitle)
            .foregroundStyle(GlassColor.textPrimary)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .frame(height: 34, alignment: .leading)
            .mainColumnFrame()
    }
}

/// State of the Parakeet banner, derived from the observed `ParakeetModelStore.status` (never from
/// the file system, which SwiftUI cannot observe). Hidden on Modele, which shows the same state.
enum ModelBanner: Equatable {
    case missing
    case downloading(percent: Int)

    @MainActor
    init?(appState: AppState, router: MainRouter) {
        guard router.selection != .modele else { return nil }
        self.init(engine: appState.settings.sttEngine, status: appState.modelStore.status)
    }

    init?(engine: STTEngine, status: ParakeetModelStore.Status) {
        guard engine == .parakeet else { return nil }
        switch status {
        case .missing, .failed:
            self = .missing
        case .downloading(let fraction):
            self = .downloading(percent: Int((fraction * 100).rounded()))
        case .optimizing, .ready:
            return nil
        }
    }
}

/// Keeps the SwiftUI window instance around after close so `openWindow(id:)` reuses it (gotcha 62),
/// and hides the title text: the transparent Dusk title bar shows only the traffic lights (the
/// page header carries the title; the window keeps it for Mission Control and the Window menu).
@MainActor
private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
    }
}

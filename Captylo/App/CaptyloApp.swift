import SwiftUI

@main
struct CaptyloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Captylo", id: WindowID.main) {
            MainView()
                .environment(delegate.appState)
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ustawienia...") {
                    delegate.appState.windowPresenter.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: .constant(delegate.showsMenuBarExtra)) {
            MenuBarMenu()
                .environment(delegate.appState)
        } label: {
            MenuBarLabel(appState: delegate.appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Scene identifiers used with `openWindow(id:)`.
enum WindowID {
    static let main = "main"
}

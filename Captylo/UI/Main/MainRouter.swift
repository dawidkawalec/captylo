import Foundation
import Observation

/// Typed navigation of the main window. The selected section lives in `WindowPresenter`
/// (the AppState slot the menu bar and the controller already use); the router adds the
/// section-level intents the screens call ("open Modele", "show the file queue").
@MainActor
@Observable
final class MainRouter {
    @ObservationIgnored private let presenter: WindowPresenter

    init(presenter: WindowPresenter) {
        self.presenter = presenter
    }

    /// Sidebar selection, bound by `MainView`.
    var selection: MainSection {
        get { presenter.selectedSection }
        set { presenter.selectedSection = newValue }
    }

    /// Switches the section without touching the window (safe while the window is already up).
    func select(_ section: MainSection) {
        selection = section
    }

    /// Brings the window forward on `section` (AppKit callers, banners, toasts).
    func open(_ section: MainSection) {
        presenter.openMain(section: section)
    }

    func openModels() {
        open(.modele)
    }

    func openHistory() {
        open(.historia)
    }

    func openFileTranscription() {
        open(.plik)
    }

    func openSettings() {
        open(.ustawienia)
    }
}

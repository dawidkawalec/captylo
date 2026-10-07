import Foundation
import Testing
@testable import Captylo

struct UIMainModelBannerTests {
    @Test func followsTheObservedModelStatus() {
        #expect(ModelBanner(engine: .local, status: .missing) == .missing)
        #expect(ModelBanner(engine: .local, status: .failed("x")) == .missing)
        #expect(ModelBanner(engine: .local, status: .downloading(0.426)) == .downloading(percent: 43))
        #expect(ModelBanner(engine: .local, status: .optimizing) == nil)
        #expect(ModelBanner(engine: .local, status: .ready) == nil)
        #expect(ModelBanner(engine: .elevenLabs, status: .missing) == nil)
    }
}

@MainActor
struct UIMainRouterTests {
    private static func makeRouter() -> (MainRouter, WindowPresenter) {
        let defaults = UserDefaults(suiteName: "UIMainRouterTests-\(UUID().uuidString)")!
        let presenter = WindowPresenter(settings: AppSettings(defaults: defaults))
        return (MainRouter(presenter: presenter), presenter)
    }

    @Test func sidebarOrderMatchesTheBrief() {
        #expect(MainSection.allCases == [.pulpit, .spotkania, .notatki, .historia, .plik, .slownik, .modele, .ustawienia])
        #expect(MainSection.allCases.map(\.title) == ["Pulpit", "Spotkania", "Notatki", "Historia", "Transkrypcja pliku", "Słownik", "Modele", "Ustawienia"])
        #expect(MainSection.notatki.symbol == "note.text")
        #expect(MainSection.spotkania.symbol == "person.2.wave.2")
        for section in MainSection.allCases {
            #expect(!section.symbol.isEmpty)
            #expect(!section.title.contains("—"), "no long dashes in UI strings")
        }
    }

    @Test func openNoteSelectsNotatkiAndLeavesTheNoteForTheScreen() {
        let (router, presenter) = Self.makeRouter()
        let id = UUID()
        presenter.openNote(id: id)
        #expect(presenter.selectedSection == .notatki)
        #expect(router.pendingNoteID == id)
        router.pendingNoteID = nil
        #expect(presenter.pendingNoteID == nil)
        router.openNote(id: id)
        #expect(presenter.pendingNoteID == id)
    }

    @Test func settingsAnchorIsSharedWithThePresenter() {
        let (router, presenter) = Self.makeRouter()
        #expect(router.settingsAnchor == nil)
        router.settingsAnchor = .account
        #expect(presenter.settingsAnchor == .account)
        presenter.settingsAnchor = nil
        #expect(router.settingsAnchor == nil)
    }

    @Test func selectionIsSharedWithThePresenter() {
        let (router, presenter) = Self.makeRouter()
        #expect(router.selection == .pulpit)

        router.select(.slownik)
        #expect(presenter.selectedSection == .slownik)

        presenter.selectedSection = .historia
        #expect(router.selection == .historia)

        router.selection = .plik
        #expect(presenter.selectedSection == .plik)
    }

    @Test func trendLabelStrideFollowsTheRange() {
        #expect(TrendChart.labelStride(forRange: 7) == 1)
        #expect(TrendChart.labelStride(forRange: 14) == 2)
        #expect(TrendChart.labelStride(forRange: 30) == 5)
    }

    @Test func trendXLabelUsesPolishShortMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        #expect(TrendChart.xLabel(date) == "25 wrz")
    }

    @Test func dashboardFormatting() {
        #expect(DashboardView.integer(999) == "999")
        #expect(DashboardView.integer(1234).filter(\.isNumber) == "1234")
        #expect(DashboardView.recordedTime(0) == "0 s")
        #expect(DashboardView.recordedTime(45) == "45 s")
        #expect(DashboardView.recordedTime(4 * 60 + 20) == "4 min")
        #expect(DashboardView.recordedTime(3600 + 5 * 60) == "1 godz. 5 min")
        #expect(DashboardView.recordedTime(2 * 3600) == "2 godz.")
        #expect(AudioPlayerView.clock(65) == "1:05")
        #expect(AudioPlayerView.clock(-3) == "0:00")
        // A long meeting's player shows hours, like the list and the details.
        #expect(AudioPlayerView.clock(3723) == "1:02:03")
    }
}

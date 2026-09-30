import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Captylo

/// Records the cues played by `ToastCenter`.
@MainActor
final class RecorderSpySoundPlayer: SoundPlaying {
    var played: [SoundCue] = []
    func play(_ cue: SoundCue) { played.append(cue) }
}

@MainActor
struct RecorderPanelTests {
    /// The tests run inside the app host; skip when there is no window server.
    private var hasDisplay: Bool {
        !NSScreen.screens.isEmpty
    }

    @Test func toastMessageWidthHugsShortTextAndCapsLongText() {
        let short = Toast.messageWidth(for: "AI pominięte")
        #expect(short > 0 && short < Toast.maxMessageWidth)
        let long = Toast.messageWidth(for: String(repeating: "Brak dostępu do mikrofonu. ", count: 5))
        #expect(long == Toast.maxMessageWidth)
    }

    @Test func longToastWrapsInsideThePanel() {
        func fitting(_ message: String) -> NSSize {
            let model = ToastModel()
            model.toast = Toast(message: message, kind: .error)
            let view = NSHostingView(rootView: ToastRootView(model: model))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }
        let short = fitting("Błąd sieci.")
        let long = fitting("Nie udało się połączyć z serwerem transkrypcji. Sprawdź połączenie z internetem i spróbuj ponownie za chwilę, albo użyj Parakeet.")
        #expect(long.height > short.height, "the long message wraps to more lines instead of running past the capsule")
        #expect(long.width <= Toast.maxMessageWidth + 120, "text column, icon, paddings and margin only")
    }

    @Test func panelControllerShowsAndHides() async throws {
        guard hasDisplay else { return }
        let model = RecorderModel(level: RecorderStubLevelSource())
        let controller = RecorderPanelController(model: model)
        #expect(controller.isVisible == false)
        #expect(controller.widgetFrame == nil)

        controller.show()
        #expect(controller.isVisible == true)
        let frame = try #require(controller.widgetFrame)
        #expect(frame.size == RecorderMetrics.compactSize)
        #expect(NSApp.isActive == false || NSApp.keyWindow == nil || !(NSApp.keyWindow is RecorderPanel))

        // Toasts sit above the expanded widget while it is open (hover).
        model.phase = .recording
        model.isExpanded = true
        let expanded = try #require(controller.widgetFrame)
        #expect(expanded.size == RecorderMetrics.expandedSize)
        #expect(expanded.minY == frame.minY, "both states share the bottom edge")

        controller.hide()
        #expect(controller.isVisible == false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isPresented == false)
        #expect(model.isExpanded == false, "the next take starts compact")

        // Show again right away: the hide must not leave the panel faded out.
        controller.show()
        #expect(controller.isVisible == true)
        controller.hide()
    }

    @Test func panelNeverBecomesKeyOrMain() {
        guard hasDisplay else { return }
        let panel = RecorderPanel()
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.frame.size == RecorderMetrics.canvas)
        #expect(panel.hasShadow == false, "the widget draws its own glows; a window shadow would outline the free bars")
    }

    @Test func pinnedExpansionSurvivesHide() async throws {
        guard hasDisplay else { return }
        let model = RecorderModel(level: RecorderStubLevelSource())
        let controller = RecorderPanelController(model: model)
        model.isExpanded = true
        model.isExpansionPinned = true
        controller.show()
        controller.hide()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isExpanded)
    }

    @Test func toastCenterQueuesAndPlaysErrorSound() async throws {
        guard hasDisplay else { return }
        let sounds = RecorderSpySoundPlayer()
        let center = ToastCenter(sounds: sounds)
        center.showInfo("Skopiowano")
        center.showError("Błąd")
        center.showAction(message: "Test", buttonTitle: "OK") {}
        #expect(sounds.played == [.error])
        center.dismissCurrent()
        try await Task.sleep(for: .milliseconds(300))
        center.dismissCurrent()
        try await Task.sleep(for: .milliseconds(300))
        center.dismissCurrent()
    }

    @Test func demoFactoryBuildsEveryState() {
        guard hasDisplay else { return }
        for state in WidgetDebugState.allCases {
            let demo = RecorderDemo.make(state: state)
            demo.driver.start()
            switch state {
            case .recording:
                #expect(demo.model.phase == .recording)
            case .transcribing:
                #expect(demo.model.phase == .transcribing)
                #expect(demo.model.timerText == "00:18")
            case .enhancing:
                #expect(demo.model.phase == .enhancing)
            }
            demo.driver.stop()
        }
    }

    @Test func demoLevelSourceStaysNormalized() {
        let level = RecorderDemoLevelSource()
        for step in 0..<400 {
            let value = level.read(now: Double(step) * 0.017)
            #expect(value >= 0 && value <= 1)
        }
        level.setEnabled(false)
        #expect(level.read(now: 1) == 0)
    }
}

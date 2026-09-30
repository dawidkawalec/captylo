import Foundation
import Observation

/// Observable state of the recorder widget. `DictationController` writes the phase, the live
/// partial text and the elapsed time; the widget reads them. The level meter is not observed:
/// `WaveformView` pulls it per frame inside a `TimelineView`.
@MainActor
@Observable
final class RecorderModel {
    var phase: DictationPhase = .idle {
        didSet {
            if phase == .idle {
                microphoneChangePending = false
            }
            if phase == .enhancing, oldValue != .enhancing {
                // The controller reads the active mode right before it switches to enhancing
                // (same main actor turn), so this is the mode that is running. Picking another
                // one in the widget now only affects the next take.
                enhancingModeName = controls.flatMap { $0.aiEnabled ? $0.activeAIMode.name : nil }
            } else if phase != .enhancing {
                enhancingModeName = nil
            }
        }
    }
    /// Name of the AI mode polishing the take, shown in the status line ("Poprawiam z AI ·
    /// Po angielsku"). Set when the phase becomes `.enhancing`, cleared when it leaves it.
    var enhancingModeName: String?
    /// Live preview text (stale partials are filtered by the controller, gotcha 59).
    var partialText = ""
    var elapsed: TimeInterval = 0
    /// Mirrors the `livePreview` setting.
    var showLivePreview = true
    /// Set by `RecorderPanelController` around show / hide to drive the in / out animation.
    var isPresented = false
    /// Expanded panel (mockups 03 / 04) instead of the compact orb row (mockup 01). Hover sets
    /// it on enter and clears it on exit unless `isExpansionPinned`.
    var isExpanded = false
    /// Keeps the widget expanded whatever the pointer does (`--design-preview widget-expanded`).
    var isExpansionPinned = false
    /// A row menu of the expanded widget is open: the pointer is over the menu, outside the
    /// panel, and the widget must not collapse under it.
    var isMenuOpen = false
    /// The microphone was changed during the take: the row says it applies from the next one.
    var microphoneChangePending = false
    /// Design preview only: the waveform shows one still frame at its crest (mockup shape).
    var isWaveformStill = false

    /// Level meter read per frame by the waveform.
    var level: any LevelSource
    /// Microphone, language, output switches and pause for the expanded widget. Nil hides those
    /// rows (tests, `--show-widget` without the app).
    @ObservationIgnored var controls: (any RecorderWidgetControls)?
    /// Orb tap and "Zakończ".
    @ObservationIgnored var onStop: () -> Void = {}
    /// Reserved for the P1 drawer and Esc handling.
    @ObservationIgnored var onCancel: () -> Void = {}

    init(level: any LevelSource) {
        self.level = level
    }

    /// Status line under the waveform.
    var statusText: String {
        switch phase {
        case .recording:
            return String(localized: "Nagrywanie... mów swobodnie")
        case .paused:
            return String(localized: "Wstrzymano")
        case .transcribing:
            return String(localized: "Transkrybuję")
        case .enhancing:
            if let name = enhancingModeName, !name.isEmpty {
                return String(localized: "Poprawiam z AI · \(name)")
            }
            return String(localized: "Poprawiam z AI")
        case .idle:
            return ""
        }
    }

    /// The compact widget (mockup 01) shows no status while recording; paused and processing
    /// get the line under the waveform.
    var compactStatusText: String {
        switch phase {
        case .recording:
            return ""
        case .enhancing:
            // The mode name goes on its own line (`compactStatusDetail`): the whole
            // "Poprawiam z AI · <mode>" is wider than the space next to the orb.
            return String(localized: "Poprawiam z AI")
        default:
            return statusText
        }
    }

    /// Second, smaller line of the compact status: the rewrite mode the take will go through
    /// while recording or paused, the AI mode while it runs.
    var compactStatusDetail: String? {
        if let mode = capturingRewriteMode {
            return mode.name
        }
        guard phase == .enhancing, let name = enhancingModeName, !name.isEmpty else { return nil }
        return name
    }

    /// Symbol before `compactStatusDetail` while recording or paused (the mode's own symbol).
    var compactStatusSymbol: String? {
        capturingRewriteMode?.symbol
    }

    /// The active mode while audio is captured, when AI is on and the mode rewrites the text
    /// (translation, e-mail, list...): the compact widget names it under the waveform, so the
    /// owner sees that the take will not paste as dictated. Cleanup keeps mockup 01 silent.
    /// Reads the observable settings behind `controls`, so a pick mid-take updates the line.
    var capturingRewriteMode: AIMode? {
        guard phase.isCapturing, let controls, controls.aiEnabled else { return nil }
        let mode = controls.activeAIMode
        return mode.kind == .rewrite ? mode : nil
    }

    /// `mm:ss`, rendered with `GlassFont.number` (monospaced digits).
    var timerText: String {
        Self.formatTimer(elapsed)
    }

    /// True while there is live text to show in the "Transkrypcja na żywo" card.
    var showsLiveCard: Bool {
        phase == .recording && !partialText.isEmpty && showLivePreview
    }

    /// "Pauza" / "Wznów" and "Zakończ" work only while audio is being captured.
    var canControlTake: Bool {
        phase.isCapturing
    }

    /// Chooses the microphone from the widget; mid-take it applies from the next take.
    func selectMicrophone(id: String?) {
        guard let controls else { return }
        let before = controls.selectedMicrophoneID
        controls.selectMicrophone(id: id)
        if phase.isCapturing, before != controls.selectedMicrophoneID {
            microphoneChangePending = true
        }
    }

    nonisolated static func formatTimer(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

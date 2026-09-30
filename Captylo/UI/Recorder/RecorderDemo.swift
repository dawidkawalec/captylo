import Foundation
import Observation
import os

// MARK: - Demo factory

/// Widget with fake audio levels and sample live text for `--show-widget` screenshots.
/// The debug runner calls `make`, then `controller.show()` and `driver.start()`.
@MainActor
enum RecorderDemo {
    static let sampleText = "Dobry pomysł na dzisiejsze spotkanie. Zaczniemy od przeglądu postępów w projekcie, a następnie omówimy kolejne kroki."
    /// Timer shown in the mockups.
    static let processingElapsed: TimeInterval = 18

    /// `startElapsed` / `prefilledWords` let the design preview open on the mockup frame
    /// (timer near 00:18, live text already there) instead of an empty take.
    static func make(
        state: WidgetDebugState,
        startElapsed: TimeInterval = 0,
        prefilledWords: Int = 0
    ) -> (model: RecorderModel, controller: RecorderPanelController, driver: RecorderDemoDriver) {
        let level = RecorderDemoLevelSource()
        let model = RecorderModel(level: level)
        let controller = RecorderPanelController(model: model)
        let driver = RecorderDemoDriver(model: model, level: level, state: state, startElapsed: startElapsed, prefilledWords: prefilledWords)
        model.controls = RecorderDemoControls(model: model, level: level)
        return (model, controller, driver)
    }
}

// MARK: - Controls

/// In-memory stand-ins for the expanded widget's menus, switches and pause: the demo and the
/// design preview never touch `AppSettings` or the audio devices.
@MainActor
@Observable
final class RecorderDemoControls: RecorderWidgetControls {
    /// Device names as macOS reports them; demo data, not UI strings.
    let microphones = [
        RecorderMicrophone(id: "demo-builtin", name: "MacBook Pro (Wbudowany)"),
        RecorderMicrophone(id: "demo-airpods", name: "AirPods Pro"),
        RecorderMicrophone(id: "demo-usb", name: "Shure MV7"),
    ]
    private(set) var selectedMicrophoneID: String?
    var language = "pl"
    var autoCopy = true
    var saveTranscript = true
    let aiModes = BuiltInAIModes.all
    private(set) var aiEnabled = true
    private(set) var activeAIModeID = BuiltInAIModes.cleanupID

    @ObservationIgnored private weak var model: RecorderModel?
    @ObservationIgnored private let level: RecorderDemoLevelSource

    init(model: RecorderModel, level: RecorderDemoLevelSource) {
        self.model = model
        self.level = level
    }

    var currentMicrophoneName: String? {
        microphones.first { $0.id == selectedMicrophoneID }?.name ?? microphones.first?.name
    }

    func selectMicrophone(id: String?) {
        selectedMicrophoneID = id
    }

    var activeAIMode: AIMode {
        aiModes.first { $0.id == activeAIModeID } ?? BuiltInAIModes.cleanup
    }

    func selectAIMode(id: UUID?) {
        guard let id else {
            aiEnabled = false
            return
        }
        guard aiModes.contains(where: { $0.id == id }) else { return }
        activeAIModeID = id
        aiEnabled = true
    }

    /// The preview has no main window to open.
    func openModes() {}

    func togglePause() {
        guard let model else { return }
        switch model.phase {
        case .recording:
            model.phase = .paused
            level.setEnabled(false)
        case .paused:
            model.phase = .recording
            level.setEnabled(true)
        default:
            break
        }
    }
}

// MARK: - Level source

/// Speech-like level: syllable modulation over word bursts and pauses, plus a little noise.
/// Stateless apart from the enable flag, so it is safe to read from any thread.
final class RecorderDemoLevelSource: LevelSource, Sendable {
    private let enabled = OSAllocatedUnfairLock(initialState: true)

    func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    func read(now: TimeInterval) -> Float {
        guard enabled.withLock({ $0 }) else { return 0 }
        // Word bursts about 0.9 s long with short gaps between them.
        let phrase = sin(now * 2 * .pi / 3.4)
        let speaking = phrase > -0.55
        guard speaking else { return Float.random(in: 0.02...0.06) }
        let syllables = 0.55 + 0.45 * sin(now * 2 * .pi * 4.3)
        let slow = 0.7 + 0.3 * sin(now * 2 * .pi * 0.37 + 1.2)
        let noise = Double.random(in: -0.06...0.06)
        let value = 0.18 + 0.62 * syllables * slow + noise
        return Float(min(max(value, 0), 1))
    }
}

// MARK: - Driver

/// Ticks the elapsed timer and grows the sample text word by word while "recording".
@MainActor
final class RecorderDemoDriver {
    private let model: RecorderModel
    private let level: RecorderDemoLevelSource
    private let state: WidgetDebugState
    private var task: Task<Void, Never>?

    static let tick: Duration = .milliseconds(100)
    static let wordInterval: TimeInterval = 0.32

    private let startElapsed: TimeInterval
    private let prefilledWords: Int

    init(model: RecorderModel, level: RecorderDemoLevelSource, state: WidgetDebugState, startElapsed: TimeInterval = 0, prefilledWords: Int = 0) {
        self.model = model
        self.level = level
        self.state = state
        self.startElapsed = startElapsed
        self.prefilledWords = prefilledWords
    }

    func start() {
        stop()
        switch state {
        case .recording:
            model.phase = .recording
            let words = RecorderDemo.sampleText.split(separator: " ").map(String.init)
            let initial = min(max(prefilledWords, 0), words.count)
            model.elapsed = startElapsed
            model.partialText = words.prefix(initial).joined(separator: " ")
            level.setEnabled(true)
            task = Task { [weak self] in
                let words = RecorderDemo.sampleText.split(separator: " ").map(String.init)
                var shown = initial
                var sinceWord: TimeInterval = 0
                let tickSeconds = 0.1
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.tick)
                    guard !Task.isCancelled, let self else { return }
                    // "Pauza" in the expanded demo widget freezes the take.
                    guard self.model.phase == .recording else { continue }
                    self.model.elapsed += tickSeconds
                    sinceWord += tickSeconds
                    if shown < words.count, sinceWord >= Self.wordInterval {
                        sinceWord = 0
                        shown += 1
                        self.model.partialText = words.prefix(shown).joined(separator: " ")
                    }
                }
            }
        case .transcribing:
            level.setEnabled(false)
            model.partialText = ""
            model.elapsed = RecorderDemo.processingElapsed
            model.phase = .transcribing
        case .enhancing:
            level.setEnabled(false)
            model.partialText = ""
            model.elapsed = RecorderDemo.processingElapsed
            // A rewrite mode, so the status line shows a mode name longer than "Czyszczenie".
            model.controls?.selectAIMode(id: BuiltInAIModes.organizeID)
            model.phase = .enhancing
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

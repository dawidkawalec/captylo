import Foundation
import Testing
@testable import Captylo

/// Silent level meter for model tests.
final class RecorderStubLevelSource: LevelSource, Sendable {
    func read(now: TimeInterval) -> Float { 0 }
}

/// Counts calls of a main-actor callback.
@MainActor
final class OpenCounter {
    var count = 0
}

@MainActor
struct RecorderModelTests {
    private func makeModel() -> RecorderModel {
        RecorderModel(level: RecorderStubLevelSource())
    }

    @Test func statusTextFollowsThePhase() {
        let model = makeModel()
        #expect(model.statusText == "")
        model.phase = .recording
        #expect(model.statusText == "Nagrywanie... mów swobodnie")
        model.phase = .paused
        #expect(model.statusText == "Wstrzymano")
        model.phase = .transcribing
        #expect(model.statusText == "Transkrybuję")
        model.phase = .enhancing
        #expect(model.statusText == "Poprawiam z AI")
        model.phase = .idle
        #expect(model.statusText == "")
    }

    @Test func timerTextIsMinutesAndSeconds() {
        let model = makeModel()
        #expect(model.timerText == "00:00")
        model.elapsed = 18
        #expect(model.timerText == "00:18")
        model.elapsed = 59.9
        #expect(model.timerText == "00:59")
        model.elapsed = 60
        #expect(model.timerText == "01:00")
        model.elapsed = 754.2
        #expect(model.timerText == "12:34")
        model.elapsed = -3
        #expect(model.timerText == "00:00")
    }

    @Test func liveCardNeedsRecordingTextAndPreviewEnabled() {
        let model = makeModel()
        #expect(model.showsLiveCard == false)
        model.phase = .recording
        #expect(model.showsLiveCard == false)
        model.partialText = "Dobry pomysł"
        #expect(model.showsLiveCard == true)
        model.showLivePreview = false
        #expect(model.showsLiveCard == false)
        model.showLivePreview = true
        model.phase = .transcribing
        #expect(model.showsLiveCard == false)
    }

    @Test func compactStatusIsSilentWhileRecording() {
        let model = makeModel()
        model.phase = .recording
        #expect(model.compactStatusText == "", "mockup 01 shows no status line")
        model.phase = .paused
        #expect(model.compactStatusText == "Wstrzymano")
        model.phase = .transcribing
        #expect(model.compactStatusText == "Transkrybuję")
    }

    @Test func takeControlsWorkOnlyWhileCapturing() {
        let model = makeModel()
        #expect(model.canControlTake == false)
        model.phase = .recording
        #expect(model.canControlTake)
        model.phase = .paused
        #expect(model.canControlTake)
        model.phase = .enhancing
        #expect(model.canControlTake == false)
    }

    @Test func microphoneChangeDuringTakeIsFlaggedUntilIdle() {
        let demo = RecorderDemo.make(state: .recording)
        let model = demo.model
        model.phase = .recording
        model.selectMicrophone(id: "demo-airpods")
        #expect(model.controls?.selectedMicrophoneID == "demo-airpods")
        #expect(model.microphoneChangePending)
        model.phase = .idle
        #expect(model.microphoneChangePending == false)

        // Choosing while idle applies right away, nothing to flag.
        model.selectMicrophone(id: nil)
        #expect(model.controls?.selectedMicrophoneID == nil)
        #expect(model.microphoneChangePending == false)
    }

    @Test func demoPauseTogglesBetweenRecordingAndPaused() throws {
        let demo = RecorderDemo.make(state: .recording)
        let controls = try #require(demo.model.controls)
        demo.model.phase = .recording
        controls.togglePause()
        #expect(demo.model.phase == .paused)
        controls.togglePause()
        #expect(demo.model.phase == .recording)
        demo.model.phase = .transcribing
        controls.togglePause()
        #expect(demo.model.phase == .transcribing)
    }

    @Test func appControlsMapTheSettings() throws {
        let suite = "com.captylo.app.tests.recorder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = FakeRecorderCoordinator()
        let controls = RecorderAppControls(settings: settings, devices: AudioDevices(settings: settings), coordinator: coordinator)

        // "Automatycznie kopiuj transkrypcję" = the transcript stays on the clipboard.
        settings.restoreClipboard = true
        #expect(controls.autoCopy == false)
        controls.autoCopy = true
        #expect(settings.restoreClipboard == false)

        controls.saveTranscript = false
        #expect(settings.saveHistory == false)
        controls.saveTranscript = true
        #expect(settings.saveHistory)

        controls.language = "en"
        #expect(settings.language == "en")

        controls.selectMicrophone(id: nil)
        #expect(controls.selectedMicrophoneID == nil)
        #expect(settings.micSelection == .systemDefault)

        controls.togglePause()
        #expect(coordinator.calls == [.togglePause])
    }

    @Test func languageMenuStartsWithAutomaticAndNamesLanguages() {
        let options = RecorderLanguageOptions.all
        #expect(options.first?.code == TranscriptionLanguages.auto)
        #expect(options.count == TranscriptionLanguages.codes.count + 1)
        #expect(RecorderLanguageOptions.name(for: TranscriptionLanguages.auto) == "Automatycznie")
        let polish = RecorderLanguageOptions.name(for: "pl", locale: Locale(identifier: "pl_PL"))
        #expect(polish == "Polski")
        #expect(RecorderLanguageOptions.name(for: "xx-unknown", locale: Locale(identifier: "pl_PL")).isEmpty == false)
    }

    // MARK: Tryb AI

    @Test func enhancingStatusNamesTheModeTakenWhenEnhancingStarts() throws {
        let demo = RecorderDemo.make(state: .recording)
        let model = demo.model
        let controls = try #require(model.controls)
        model.phase = .recording
        controls.selectAIMode(id: BuiltInAIModes.englishID)
        model.phase = .enhancing
        #expect(model.enhancingModeName == "Po angielsku")
        #expect(model.statusText == "Poprawiam z AI · Po angielsku")
        // The compact widget splits it in two lines so it never runs into the orb.
        #expect(model.compactStatusText == "Poprawiam z AI")
        #expect(model.compactStatusDetail == "Po angielsku")

        // A pick made while AI runs is for the next take; the line keeps the running mode.
        controls.selectAIMode(id: BuiltInAIModes.tasksID)
        #expect(model.statusText == "Poprawiam z AI · Po angielsku")

        model.phase = .idle
        #expect(model.enhancingModeName == nil)
        #expect(model.compactStatusDetail == nil)
    }

    @Test func enhancingStatusWithoutControlsOrAIHasNoModeName() throws {
        let bare = makeModel()
        bare.phase = .enhancing
        #expect(bare.statusText == "Poprawiam z AI")

        let demo = RecorderDemo.make(state: .recording)
        demo.model.controls?.selectAIMode(id: nil)
        demo.model.phase = .enhancing
        #expect(demo.model.statusText == "Poprawiam z AI")
    }

    @Test func aiModeMenuListsNoAIThenEveryModeWithOneCheckmark() throws {
        let demo = RecorderDemo.make(state: .recording)
        let controls = try #require(demo.model.controls)

        var items = RecorderAIModeOptions.menuItems(for: controls)
        #expect(items.map(\.title) == ["Bez AI"] + BuiltInAIModes.all.map(\.name) + ["Edytuj tryby..."])
        #expect(items.filter(\.isChecked).map(\.title) == ["Czyszczenie"])
        #expect(items.dropFirst().dropLast().map(\.systemImage) == BuiltInAIModes.all.map { Optional($0.symbol) })
        #expect(items[1].startsGroup)
        #expect(items.last?.startsGroup == true)
        #expect(RecorderAIModeOptions.currentName(of: controls) == "Czyszczenie")

        // Picking a mode from the menu runs its action.
        items[3].action()
        #expect(controls.aiEnabled)
        #expect(controls.activeAIMode.id == BuiltInAIModes.organizeID)
        #expect(RecorderAIModeOptions.currentName(of: controls) == "Uporządkuj myśli")

        items = RecorderAIModeOptions.menuItems(for: controls)
        items[0].action()
        #expect(controls.aiEnabled == false)
        #expect(RecorderAIModeOptions.currentName(of: controls) == "Bez AI")
        items = RecorderAIModeOptions.menuItems(for: controls)
        #expect(items.filter(\.isChecked).map(\.title) == ["Bez AI"])
    }

    @Test func aiModeChoiceDrivesTheSettings() throws {
        let suite = "com.captylo.app.tests.recorder-ai.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controls = RecorderAppControls(settings: settings, devices: AudioDevices(settings: settings), coordinator: FakeRecorderCoordinator())

        #expect(settings.aiEnabled == false)
        #expect(RecorderAIModeOptions.currentName(of: controls) == "Bez AI")
        #expect(controls.aiModes.map(\.id) == BuiltInAIModes.all.map(\.id))

        controls.selectAIMode(id: BuiltInAIModes.emailID)
        #expect(settings.aiEnabled)
        #expect(settings.aiActiveModeID == BuiltInAIModes.emailID)
        #expect(controls.activeAIMode.name == "E-mail")

        // "Bez AI" only flips the master switch; the mode stays for the next time AI is on.
        controls.selectAIMode(id: nil)
        #expect(settings.aiEnabled == false)
        #expect(settings.aiActiveModeID == BuiltInAIModes.emailID)

        // An id that is not in the list changes nothing.
        controls.selectAIMode(id: UUID())
        #expect(settings.aiEnabled == false)
        #expect(settings.aiActiveModeID == BuiltInAIModes.emailID)

        // The user's own modes are listed and selectable too.
        let own = settings.addMode()
        controls.selectAIMode(id: own.id)
        #expect(settings.aiEnabled)
        #expect(controls.activeAIMode.id == own.id)
        #expect(RecorderAIModeOptions.menuItems(for: controls).dropLast().last?.isChecked == true)
    }

    @Test func editModesItemOpensModele() throws {
        let suite = "com.captylo.app.tests.recorder-edit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let opened = OpenCounter()
        let controls = RecorderAppControls(
            settings: settings,
            devices: AudioDevices(settings: settings),
            coordinator: FakeRecorderCoordinator(),
            openModes: { opened.count += 1 }
        )
        let edit = try #require(RecorderAIModeOptions.menuItems(for: controls).last)
        #expect(edit.id == "edit-modes")
        #expect(edit.isChecked == false)
        edit.action()
        #expect(opened.count == 1)
        // Opening Modele changes no setting.
        #expect(settings.aiEnabled == false)
    }

    @Test func compactWidgetNamesARewriteModeWhileCapturing() throws {
        let demo = RecorderDemo.make(state: .recording)
        let model = demo.model
        let controls = try #require(model.controls)
        model.phase = .recording

        // Cleanup stays silent, like mockup 01.
        #expect(model.compactStatusDetail == nil)
        #expect(model.compactStatusSymbol == nil)

        controls.selectAIMode(id: BuiltInAIModes.englishID)
        #expect(model.compactStatusText == "")
        #expect(model.compactStatusDetail == "Po angielsku")
        #expect(model.compactStatusSymbol == BuiltInAIModes.english.symbol)

        model.phase = .paused
        #expect(model.compactStatusText == "Wstrzymano")
        #expect(model.compactStatusDetail == "Po angielsku")

        // "Bez AI": nothing will be rewritten, so nothing to warn about.
        controls.selectAIMode(id: nil)
        #expect(model.compactStatusDetail == nil)

        controls.selectAIMode(id: BuiltInAIModes.englishID)
        model.phase = .transcribing
        #expect(model.compactStatusDetail == nil)
    }

    @Test func callbacksDefaultToNoOps() {
        let model = makeModel()
        model.onStop()
        model.onCancel()
        var stopped = false
        model.onStop = { stopped = true }
        model.onStop()
        #expect(stopped)
    }
}

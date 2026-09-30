import AppKit
import SwiftUI

/// Content of the menu bar extra (brief "App shell"): start / stop, copy last transcript,
/// microphone and AI mode submenus, open app, settings, Dock and login toggles, quit.
@MainActor
struct MenuBarMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let phase = appState.dictationController.phase

        OpenWindowBridge(presenter: appState.windowPresenter)

        if phase.isCapturing {
            Button("Zakończ dyktowanie") {
                Task { await appState.coordinator.stop() }
            }
        } else {
            Button(startTitle) {
                Task { await appState.coordinator.start() }
            }
            .disabled(phase.isProcessing)
        }

        Button("Kopiuj ostatnią transkrypcję") {
            Task {
                guard let text = await appState.database.lastCompletedText() else {
                    appState.toasts.showInfo(String(localized: "Historia jest pusta."))
                    return
                }
                appState.textOutput.copy(text)
            }
        }

        Menu("Mikrofon") {
            MicrophonePicker(devices: appState.audioDevices)
        }

        Menu("Tryb AI") {
            AIModePicker(settings: appState.settings)
            Divider()
            Button("Edytuj tryby...") {
                appState.windowPresenter.openMain(section: .modele)
            }
        }

        Divider()

        Button("Otwórz Captylo") {
            appState.windowPresenter.openMain(section: .pulpit)
        }
        Button("Ustawienia...") {
            appState.windowPresenter.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Toggle("Ukryj ikonę w Docku", isOn: $settings.menuBarOnly)
        Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
            get: { appState.launchAtLogin.isEnabled },
            set: { appState.launchAtLogin.setEnabled($0) }
        ))
        .disabled(appState.launchAtLogin.isUnavailable)

        Divider()

        Button("Zakończ Captylo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var startTitle: String {
        let hotkey = appState.hotkeyController.hotkey ?? appState.settings.hotkey
        return String(localized: "Rozpocznij dyktowanie (\(hotkey.displayName))")
    }
}

/// "Bez AI" plus every AI mode, checkmark on "Bez AI" when AI is off, else on the active mode.
/// Same choices as the widget's "Tryb AI" row (`RecorderAIModeOptions`); a pick made during a
/// take applies to it, because the controller reads the mode when the take stops. The submenu
/// ends with "Edytuj tryby...", which opens Modele (added in `MenuBarMenu`).
@MainActor
private struct AIModePicker: View {
    let settings: AppSettings

    var body: some View {
        Toggle("Bez AI", isOn: Binding(
            get: { !settings.aiEnabled },
            set: { if $0 { RecorderAIModeOptions.select(id: nil, in: settings) } }
        ))
        Divider()
        let activeID = settings.aiEnabled ? settings.activeMode.id : nil
        ForEach(settings.aiModes) { mode in
            Toggle(isOn: Binding(
                get: { activeID == mode.id },
                set: { if $0 { RecorderAIModeOptions.select(id: mode.id, in: settings) } }
            )) {
                Label {
                    Text(verbatim: mode.name)
                } icon: {
                    Image(systemName: mode.symbol)
                }
            }
        }
    }
}

/// "Domyślny systemowy" plus every input, checkmark on the effective selection.
@MainActor
private struct MicrophonePicker: View {
    let devices: AudioDevices

    var body: some View {
        Toggle("Domyślny systemowy", isOn: Binding(
            get: { devices.selection.isSystemDefault },
            set: { if $0 { devices.select(nil) } }
        ))
        if !devices.inputs.isEmpty {
            Divider()
        }
        ForEach(devices.inputs) { input in
            Toggle(input.name, isOn: Binding(
                get: { devices.selection == .device(uid: input.uid, modelUID: input.modelUID) },
                set: { if $0 { devices.select(input) } }
            ))
        }
    }
}

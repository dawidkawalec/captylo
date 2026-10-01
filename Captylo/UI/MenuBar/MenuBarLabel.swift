import AppKit
import SwiftUI

/// Status item glyph: the template `MenuBarIcon` asset, swapped for `MenuBarIconRecording`
/// while a take or a meeting is being recorded (SF `waveform` / `record.circle` when an asset is
/// missing).
/// A status item renders its label as one flat image, so the recording state has to be a
/// separate asset rather than an overlay. Also hosts the `OpenWindowBridge`, because the label
/// scene is alive even while the menu is closed.
@MainActor
struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        let recording = appState.dictationController.phase.isCapturing || appState.meetingRecorder.isRecording
        icon(recording: recording)
            .background(OpenWindowBridge(presenter: appState.windowPresenter))
            .accessibilityLabel(recording ? Text("Captylo, nagrywanie") : Text("Captylo"))
    }

    @ViewBuilder
    private func icon(recording: Bool) -> some View {
        let asset = recording ? "MenuBarIconRecording" : "MenuBarIcon"
        if NSImage(named: asset) != nil {
            Image(asset)
        } else {
            Image(systemName: recording ? "record.circle" : "waveform")
        }
    }
}

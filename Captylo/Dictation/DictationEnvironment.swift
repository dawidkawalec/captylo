import Foundation

/// Everything `DictationController` needs, injected once by `AppState` (brief 4.2: no singletons).
/// Module seams are the protocols from `DictationTypes.swift`; shell hooks are closures so the
/// controller never reaches back into `AppState` or the window layer.
@MainActor
struct DictationEnvironment {
    let settings: AppSettings
    let devices: AudioDevices
    let capture: any AudioCapturing
    let sounds: any SoundPlaying
    let systemMute: any SystemMuting
    let router: any TranscriptionRouting
    let livePreview: any LivePreviewing
    let enhancer: any TextEnhancing
    let dictionary: DictionaryStore
    /// Self-learning: spelled words and (later) edits of pasted text become dictionary entries.
    let learning: any CorrectionLearning
    /// Watches the pasted text for corrections (Accessibility, read-only).
    let pasteWatcher: any PasteWatching
    let output: any TextDelivering
    let widget: any RecorderWidgetPresenting
    let toasts: any ToastPresenting
    let recorderModel: RecorderModel
    let database: Database
    /// False on the in-memory fallback store: rows vanish at quit, so a take keeps no WAV either
    /// (treated like "Zapisuj historię" off).
    let persistsHistory: Bool

    /// Local model files on disk (a cloud engine still works without them).
    let isLocalModelInstalled: @MainActor () -> Bool
    /// Local model loaded and warm: the live preview only runs then.
    let isLocalModelReady: @MainActor () -> Bool
    /// `HotkeyTap.setEscapeArmed`: Esc is swallowed only while the widget is visible.
    let setEscapeArmed: @MainActor (Bool) -> Void
    /// Called after a row was saved (bump `statsVersion`, run retention).
    let didSave: @MainActor () -> Void
    /// Opens the main window on the Modele tab (model missing).
    let openModels: @MainActor () -> Void
    /// Opens System Settings > Privacy & Security > Accessibility (paste failed).
    let openAccessibilitySettings: @MainActor () -> Void
    /// Opens System Settings > Privacy & Security > Microphone (mic denied).
    let openMicrophoneSettings: @MainActor () -> Void
}

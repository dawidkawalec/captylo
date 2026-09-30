# Port note: App shell, onboarding, settings, menu bar, audio file transcription

Source: `<old repo>/VoiceInk` (VoiceInk v2.11 fork). Read-only analysis.

## 1. What it does for the user

**Essential (keep):**
- A single main window (fixed width, sidebar + detail) and a menu bar icon. The app keeps running with no windows open.
- "Hide Dock icon" (menu-bar-only mode) and "Launch at login".
- First-run onboarding: permissions (Microphone + Accessibility), microphone choice, model setup (download local Parakeet, or a cloud provider plus API key), choosing a shortcut, and a practice dictation.
- Settings: primary shortcut + mode (Toggle / Push-to-Talk / Hybrid), cancel shortcut (Esc), keep clipboard + restore delay, mute system audio while recording, start/stop sounds, microphone picker, language (user = `pl`).
- Menu bar menu: Toggle Recorder, Copy Last Transcription, Open VocaType / Settings, Hide Dock Icon, Launch at Login, Quit.
- Audio file transcription: drag and drop or "Choose Files", with a sequential queue and results saved to History.
- "Open With VocaType" from Finder for audio and video files (`CFBundleDocumentTypes`, `application(_:open:)`).
- A reminder banner at launch when Accessibility is missing.

**DROP (bloat):**
- Sparkle and everything tied to it: `UpdaterViewModel`, the "Check for Updates" menu and command, `appcast.xml`, `SU*` plist keys, mach-lookup entitlements, `scripts/release.sh`.
- License / "VocaType Pro" (onboarding license step, `LicenseViewModel` refresh on didBecomeActive and didWake).
- Modes (Power Mode), onboarding "Context Awareness" and "Trust" screens, the 3-step "experience" demo (enhance and email demos), the Screen Recording permission, and `NSAppleEventsUsageDescription` (used only for browser URL detection and AppleScript paste).
- AnnouncementsService, GitHubStarPromptCoordinator, confetti, AppIntents/AppShortcuts, OnboardingV2Migration, Ollama probing, Import/Export settings, Diagnostics log export, the separate History NSWindow (1250x750), the DEBUG "Toggle Menu Bar Only" WindowGroup.
- Settings bloat: secondary shortcut, paste-last-enhanced, retry-last shortcut, middle-click recording + delay, paste method (AppleScript), appearance picker, UI language picker, recorder style (notch vs mini; the new app has one widget), pause media + resume delay, microphone priority order, auto-update toggles, announcements.
- File transcription bloat: the per-queue "Mode" picker, the enhancement phase during file transcription (make it optional at most), and re-transcribe-with-mode.
- CloudKit sync of the dictionary (`iCloud.com.prakashjoshipax.VoiceInk`), `aps-environment`, `network.server` entitlement.

## 2. Key files and control flow

| Area | Files |
|---|---|
| Entry + scenes | `VoiceInk/VoiceInk.swift` (496 lines: builds all services, SwiftData, `Window` + `MenuBarExtra`) |
| Lifecycle | `VoiceInk/AppDelegate.swift`, `VoiceInk/MenuBarManager.swift`, `VoiceInk/WindowManager.swift` (`AppPresentationPolicy`) |
| Defaults | `VoiceInk/AppDefaults.swift` (`UserDefaults.register`) |
| Login item | `VoiceInk/Services/LaunchAtLoginManager.swift` (`SMAppService.mainApp`) |
| Menu bar | `VoiceInk/Views/MenuBarView.swift` |
| Main window | `VoiceInk/Views/ContentView.swift` (`ViewType`, `MainWindowNavigation`), `VoiceInk/Views/Sidebar/AppSidebar.swift` |
| Onboarding | `VoiceInk/Views/Onboarding/*` (27 files, about 5k lines). Core: `OnboardingView`, `OnboardingCoordinator`, `OnboardingFlowController`, `OnboardingPermissionController`, `OnboardingPermissionModels`, `OnboardingLockedTextEditor` |
| Settings | `VoiceInk/Views/Settings/SettingsView.swift`, `AudioSetupView.swift`, `CustomSoundSettingsView.swift`, `History/HistorySettingsPanel.swift` |
| File transcription | `VoiceInk/Views/AudioTranscribeView.swift`, `Services/AudioFileTranscriptionManager.swift` (queue), `Services/AudioFileTranscriptionService.swift` (re-transcribe), `Transcription/Engine/AudioFileProcessor.swift` (decode to 16k), `Services/SupportedMedia.swift`, `Models/AudioFileQueueItem.swift` |
| Plist / signing | `VoiceInk/Info.plist`, `VoiceInk.entitlements`, `VoiceInk.local.entitlements`, `LocalBuild.xcconfig`, `Makefile` |

### 2.1 Lifecycle
1. `App.init`: `URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)` so API responses never reach `Cache.db` (privacy, keep). Then `AppDefaults.registerDefaults()`, then the SwiftData `ModelContainer` with 3 stores under `~/Library/Application Support/com.prakashjoshipax.VoiceInk/`: `default.store` (Transcription), `dictionary.store` (VocabularyWord, WordReplacement), `stats.store` (SessionMetric). If the persistent store fails, it falls back to in-memory storage and shows an NSAlert. The user's real data is there, along with `Recordings/` and `WhisperModels/`. Relevant for the later data migration.
2. Scenes: `Window("VocaType", id: "main")` shows `OnboardingView` until `@AppStorage("hasCompletedOnboardingV2")` is true, then `ContentView` (the root is swapped in place in the same window). Modifiers: `.windowStyle(.hiddenTitleBar)`, `.defaultSize(950x750)`, `.windowResizability(.contentSize)`, and `.commands { CommandGroup(replacing: .newItem) {} }` to remove "New Window".
3. `MenuBarExtra(isInserted:)` with `.menuBarExtraStyle(.menu)`. The label is the `menuBarIcon` asset (template-rendering-intent = template) resized to 22 pt tall.
4. `AppDelegate`:
   - `applicationDidFinishLaunching`: apply the activation policy.
   - `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
   - `applicationShouldHandleReopen` (Dock click): show the main window, or post `.showMainWindowRequested` when no window exists.
   - `application(_:open:)`: for a supported media URL, route to "Transcribe Audio". On cold start it stashes `pendingOpenFileURL` and does not create a window, to avoid a duplicate window or tab. `ContentView.onAppear` then navigates and posts `.openFileForTranscription` after 0.3 s.
5. Activation policy: UserDefaults `IsMenuBarOnly` selects `.accessory` or `.regular`. Opening any user window temporarily switches to `.regular` and calls `activate(ignoringOtherApps:)`. A global `NSWindow.willCloseNotification` observer switches back to `.accessory` and calls `NSApp.deactivate()` once no titled, `.normal`-level windows remain visible. The level filter keeps the recorder NSPanel from counting as a window.
6. Opening the window from the menu: `@Environment(\.openWindow)` works only inside SwiftUI views. For AppKit callers, the old app hides a zero-size `MainWindowRequestBridge` view in the MenuBarExtra label that listens for `.showMainWindowRequested` and calls `openWindow(id: "main")`.
7. Launch at login: `SMAppService.mainApp.register()` / `unregister()`, with `status == .enabled` read in `Task.detached` because it can block. A generation counter guards against races. The rewrite can use a single @MainActor wrapper.
8. At launch, when `ContentView` appears: if `!AXIsProcessTrusted()`, show an in-app toast "Accessibility permission is not provided" with an "Open Settings" button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
9. Model prewarm (keep; details are in the transcription note): about 3 s after launch and on `NSWorkspace.didWakeNotification`, controlled by `PrewarmModelOnWake` (default true).

### 2.2 Main window and sidebar
- Width is fixed at 950 (min and max), height at least 750. The sidebar is 220 wide, with `VisualEffectView(material: .sidebar, blendingMode: .behindWindow)` and the detail area tinted at 50%.
- Old sidebar: Dashboard, Modes, Transcribe, History, Dictionary, AI Models, Audio, then Settings and VocaType Pro at the bottom. Rows are 38 pt with a 24 pt colored SF Symbol tile.
- **New sidebar:** Dashboard (stats), History, Transcribe File, Dictionary, Models (transcription model + AI provider), Settings (mic and sounds folded in). Remove Modes, Audio and License.
- Navigation uses a string-based `NotificationCenter` `.navigateToDestination` with a `ViewType.rawValue`. Replace it with a typed `@Observable` router.

### 2.3 Menu bar menu (old contents, in order)
Before onboarding: "Complete Onboarding", "Quit". After onboarding: Toggle Recorder; Mode submenu (DROP); Audio Input device submenu with a check mark (keep, cheap); Retry Last Transcription (DROP); Copy Last Transcription (Cmd+Shift+C); History (Cmd+Shift+H, opened a separate window, so route it to the sidebar instead); Show/Hide Dock Icon (Cmd+Shift+D); Launch at Login toggle; Settings (Cmd+,); Check for Updates (DROP); Quit VocaType.

### 2.4 Onboarding (old, 8 stages; the step count varies, shown as a segmented ring with % at bottom-left)
The stage is persisted in `UserDefaults["onboardingStage"]` so the flow resumes after a relaunch (for example after granting Accessibility). `reconcileStage()` rewinds to the first incomplete step on every `didBecomeActive` if a permission was revoked. Transitions: `.transition(.opacity)` plus `.animation(.easeInOut(duration: 0.22), value: stage)`. Minimum size is 820x680. Each screen has a hero header (56 pt icon tile, 30 pt bold title, 14 pt muted subtitle) and a bottom bar (Back 132x42 on the left, primary button on the right, disabled until the step's requirement is met).
1. **permissions**: rows for Microphone (required), Accessibility (required) and Screen Recording (optional, DROP). Rows unlock in sequence: a later row is locked until earlier required ones are granted. After a request, the app polls every 1 s for 60 s, and also rechecks on `NSApplication.didBecomeActiveNotification` and via a "Recheck" button. The Screen Recording row shows "Restart after enabling" with a Quit button.
2. **microphone**: CoreAudio device list. Preselection order: saved device ID, then saved UID, then system default, then first device. A Refresh button spins its icon 360 degrees. Saving sets `audioInputMode = custom` and `selectedAudioDeviceUID`. Skipping this is fine in the rewrite if the default device is used, but keep the picker in Settings.
3. **model**: a Local/Cloud segmented control. Local = FluidAudio model named `parakeet-tdt-0.6b-v3` with a download card (NVIDIA logo, size pill, "25+ languages", "Local", progress). Continue is disabled while downloading. Cloud = provider picker plus API key verification.
4. **api**: AI enhancement provider (default Groq), key field, "Get API key" link (for example `https://console.groq.com/keys`) and Verify. Skipping shows the alert "Set up AI enhancement later?". In the rewrite, make this step optional and off by default.
5. **experience**: 3 demos (dictation, enhance, email). Each has an intro phase (pick a shortcut with the `ShortcutRecorder` control) and a practice phase: a fake "Notes" window with traffic lights, sample text to read aloud, and a **locked NSTextView** that rejects typing and accepts only paste, so the only way to complete the step is to actually dictate. A step is complete when the trimmed text is non-empty and differs from the initial text. Keep only the dictation demo.
6. **contextAwareness**, 7. **trust**, 8. **license**: DROP.
The flow completes by removing all `onboarding*` keys and setting `hasCompletedOnboardingV2 = true`. Settings has a "Reset Onboarding" button that sets it back to false.

### 2.5 Settings inventory (old key, default, verdict)
| Setting | UserDefaults key / default | Verdict |
|---|---|---|
| Primary shortcut + mode | ShortcutStore `primaryRecording`, mode toggle/pushToTalk/hybrid | ESSENTIAL |
| Cancel recording | `.cancelRecorder`, default `kVK_Escape` no modifiers | ESSENTIAL |
| Paste last transcription | `.pasteLastTranscription` | keep (optional) |
| Keep clipboard content | `restoreClipboardAfterPaste`=true, `clipboardRestoreDelay`=2.0 (choices 0.25/0.5/1/2/3/4/5 s; user has 2.5) | ESSENTIAL |
| Append trailing space | `AppendTrailingSpace`=true | keep (hidden default ok) |
| Text formatting (paragraphs) | `IsTextFormattingEnabled`=true | keep hidden |
| VAD | `IsVADEnabled`=true | keep hidden |
| Language | `SelectedLanguage`="en" (user: `pl`) | ESSENTIAL (in Models) |
| Live text display | `ShowLiveTranscript`=true | keep, no toggle needed |
| Hide Dock icon | `IsMenuBarOnly`=false | ESSENTIAL |
| Launch at login | SMAppService | ESSENTIAL |
| Mute audio while recording | `isSystemMuteEnabled`=true (user: on) | ESSENTIAL |
| Start/stop sounds | CustomSoundManager built-in keys | keep on/off only |
| Microphone | `audioInputMode`, `selectedAudioDeviceUID` | ESSENTIAL (simple picker) |
| Auto-delete transcripts / audio | `IsTranscriptionCleanupEnabled`=false (1440 min), `IsAudioCleanupEnabled`=false (7 d) | optional, later |
| Prewarm on wake | `PrewarmModelOnWake`=true | keep hidden |
| Everything listed under DROP in section 1 | | DROP |

### 2.6 Audio file transcription
- **Supported:** extension allowlist `wav mp3 m4a aiff mp4 mov aac flac caf amr ogg oga opus 3gp`, or a UTType that conforms to `.audio` or `.movie`. Ogg, Opus and AMR support through AVFoundation was never verified in the code, so test them before advertising them. No ffmpeg anywhere.
- **UI:** empty state is a dashed 480x200 drop zone ("Drop audio or video files here" / "Choose Files" / format list). `NSOpenPanel` uses `allowsMultipleSelection = true` and `allowedContentTypes = [.audio, .movie]`. The drop handler loads `fileURL`, falling back to `Data` and then `String`. Queue rows show filename and status with phases loading, processingAudio, transcribing, (enhancing), completed or failed(message), plus Retry and Remove. A top bar holds count, Add, Start/Cancel and Clear. The last completed item auto-expands.
- **Pipeline per item** (`@MainActor` manager running a `Task`, sequential):
  1. `startAccessingSecurityScopedResource()`.
  2. Decode to `[Float]` 16 kHz mono.
  3. Get the duration from `AVURLAsset.load(.duration)`.
  4. Write an Int16 16 kHz mono WAV to `Recordings/transcribed_<UUID>.wav` (in `pl.kawalec.VocaType`, which is inconsistent with the store directory).
  5. `serviceRegistry.transcribe(audioURL:model:context:)`, the same path as dictation.
  6. `TranscriptionOutputFilter.filter`, then trim, then optional `ParagraphFormatter.format`, then `WordReplacementService.applyReplacements` (dictionary).
  7. Optional AI enhancement. If enhancement fails, the failure message is stored in `enhancedText`.
  8. Insert a `Transcription` and post `.transcriptionCreated` / `.transcriptionCompleted`.
  Cancellation resets in-flight items to `.pending`.
- **Parakeet shortcut:** `FluidAudioTranscriptionService` passes the URL straight to `asrManager.transcribe(audioURL, decoderState:, language:)`, and FluidAudio resamples internally. For a local model, the rewrite can skip its own conversion. For cloud (Gemini/Groq), upload the converted 16k WAV, which is much smaller than video.

### 2.7 Info.plist, entitlements, build
- Info.plist: `NSMicrophoneUsageDescription` (ESSENTIAL); `NSAppleEventsUsageDescription` and `NSScreenCaptureUsageDescription` (DROP); `LSUIElement=false` (the Dock policy is set at runtime, keep it that way); `SUEnable*` (DROP); `CFBundleDocumentTypes` = role Viewer, `LSHandlerRank` Alternate, `LSItemContentTypes` public.audio + public.movie (KEEP). Accessibility needs no plist key.
- Build settings: `ENABLE_HARDENED_RUNTIME=YES`, sandbox off (`com.apple.security.app-sandbox=false`), `MACOSX_DEPLOYMENT_TARGET=14.4`, `SWIFT_VERSION=5.0` (the new app uses Swift 6), bundle `pl.kawalec.VocaType`, team `V6J6A3VWY2`, `LSApplicationCategoryType=public.app-category.productivity`.
- Minimal entitlements for the new app: `com.apple.security.device.audio-input`, `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-only` (harmless). Drop the iCloud/CloudKit/aps, `network.server`, `screen-capture`, `automation.apple-events`, `mach-lookup` (Sparkle) and `keychain-access-groups` entries (the last needs a team ID; the local entitlements already omit it).
- `LocalBuild.xcconfig`: `CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Manual`, empty `DEVELOPMENT_TEAM`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) LOCAL_BUILD`.
- `make local`: `rm -rf .local-build`, then `xcodebuild -project ... -scheme VoiceInk -configuration Debug -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" build`, then `ditto` to `~/Downloads/VocaType.app` and `xattr -cr`. The entitlements path must be absolute, because relative paths break SPM package targets. AGENTS.md also notes `-skipPackagePluginValidation -skipMacroValidation`, and `xcodebuild -downloadComponent MetalToolchain` (needed only for MLX, which will not be in the new app).

## 3. Gotchas (easy to get wrong)
- **TCC with ad-hoc signing:** every rebuild signed with `-` gets a new cdhash, so the Accessibility entry goes stale. The app shows as enabled but `AXIsProcessTrusted()` returns false. Fix: sign local builds with a stable self-signed certificate (for example "VocaType Dev" in Keychain) or a Developer ID, or run `tccutil reset Accessibility <bundle-id>` and re-grant after each build. Use a **new bundle ID** (for example `pl.kawalec.VocaType2`) so it does not collide with the old app's TCC entries, defaults and Keychain.
- `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` shows the system prompt only once per app identity. The old app also opens the Settings URL directly and then polls. Accessibility often only takes effect for CGEvent posting after a relaunch; offer a "Relaunch" button if polling stays false.
- The microphone request callback arrives on an arbitrary queue, so hop to main. If the status is `.denied` or `.restricted`, `requestAccess` does nothing, so open `...?Privacy_Microphone` instead.
- The main window with `isReleasedWhenClosed = false` plus a stable `identifier` allows reuse. SwiftUI may create a second window (reopen or `openWindow` race). `configureWindow` detects a duplicate identifier and closes the new window.
- Presenting from `.accessory` needs `setActivationPolicy(.regular)` **before** `activate(ignoringOtherApps: true)`. The old code calls `makeKeyAndOrderFront` twice and falls back to `orderFrontRegardless()` when the window did not become key (macOS 14 activation quirk).
- `restoreAccessory...` runs `DispatchQueue.main.async` so the closing window is already invisible when it counts windows.
- **AVAudioConverter bug in `AudioFileProcessor.readUsingAudioFile`:** the input block always returns the same buffer with `.haveData`, so the converter can pull it twice and duplicate audio. The converter is also rebuilt per 50,000,000-frame chunk, which loses resampler state at chunk boundaries. Return the buffer once, then `.endOfStream`, and keep one converter per file.
- `AVAudioFile` fails with `-50` on some mp4/m4a files (upstream issue #799). The fallback is `AVAssetReader` with LPCM float32 16k mono output settings. Use AVAssetReader as the **only** decode path: it handles video containers and does the resampling itself.
- Samples are peak-normalized per chunk. That is harmless for one chunk, but it gives inconsistent gain across chunks. For ASR, either don't normalize or normalize once globally.
- The whole file is held in memory as `[Float]`: 1 h at 16 kHz is about 230 MB. Acceptable for now, but stream to disk if long files matter.
- `ModelContainer` is created in `App.init()`. `@StateObject` wrappers are assigned manually (`_x = StateObject(wrappedValue:)`). In Swift 6, prefer an `@Observable @MainActor final class AppState` created once and injected with `.environment`.

## 4. Excerpts worth copying the idea of

Dock policy restore when the last user window closes (MenuBarManager + WindowManager):
```swift
@objc private func userFacingWindowWillClose(_ notification: Notification) {
    guard isMenuBarOnly,
        let window = notification.object as? NSWindow,
        window.level == .normal,
        window.styleMask.contains(.titled)
    else { return }
    AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed()
}
enum AppPresentationPolicy {
    static func activateForUserFacingWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    static func restoreAccessoryIfNeededAfterUserFacingWindowClosed() {
        DispatchQueue.main.async {
            let menuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
            let hasVisibleUserWindows = NSApplication.shared.windows.contains {
                $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled) }
            guard menuBarOnly, !hasVisibleUserWindows else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.deactivate()
        }
    }
}
```

Main window config (WindowManager.configureWindow, reached via a `WindowAccessor` NSViewRepresentable):
```swift
window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = .clear
window.isOpaque = false
window.isReleasedWhenClosed = false
window.collectionBehavior = [.fullScreenPrimary]
window.minSize = NSSize(width: 950, height: 750)
window.maxSize = NSSize(width: 950, height: .greatestFiniteMagnitude)
window.setFrameAutosaveName("VocaTypeMainWindowFrame")   // + center() if no saved frame
window.identifier = NSUserInterfaceItemIdentifier("...mainWindow"); window.delegate = self
```

Permission checks and requests (OnboardingPermissionController):
```swift
case .microphone: switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted; case .denied: .denied; case .restricted: .restricted
    case .notDetermined: .needsAccess; @unknown default: .unknown }
case .accessibility: AXIsProcessTrusted() ? .granted : .needsAccess
// request accessibility:
let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
AXIsProcessTrustedWithOptions(options)
NSWorkspace.shared.open(URL(string:
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
// then poll: for _ in 0..<60 { refresh(); if allGranted { return }; try? await Task.sleep(for: .seconds(1)) }
```

Robust decode to 16 kHz mono float (AudioFileProcessor.readUsingAssetReader, the recommended sole path):
```swift
let asset = AVURLAsset(url: url)
guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ... }
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
output.alwaysCopiesSampleData = false
reader.add(output); guard reader.startReading() else { throw reader.error ?? ... }
while let sb = output.copyNextSampleBuffer() {
    try Task.checkCancellation()
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
    var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(bb) / 4)
    _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0,
            dataLength: $0.count, destination: $0.baseAddress!) }
    samples.append(contentsOf: chunk)
}
if reader.status == .failed { throw reader.error! }
```

Onboarding "dictate, don't type" field (OnboardingLockedTextEditor): an `NSTextView` subclass whose `insertText`, `deleteBackward`, `deleteForward`, `cut`, `delete` and `insertNewline` are no-ops unless the text comes from `paste(_:)`, which sets `isApplyingPaste = true` around `super.paste`. The paste subsystem simulates Cmd+V, so dictated text lands there and the user's own typing is ignored. Focus the field about 0.2 s after the shortcut is set (`window.makeFirstResponder`).

## 5. Recommended minimal design for the rewrite
1. `VocaTypeApp` (@main, Swift 6): `Window("VocaType", id: "main")` (root = `OnboardingView` or `MainView` based on `@AppStorage("onboardingDone")`) plus `MenuBarExtra(.menu)`. `CommandGroup(replacing: .newItem) {}`. No Sparkle and no debug scenes.
2. `AppState` (`@Observable @MainActor`, created once): owns `Settings`, `PermissionService`, `Transcriber`, `HistoryStore`, `Router`. Injected with `.environment`.
3. `AppDelegate`: terminate-after-last-window `false`, reopen calls `WindowPresenter.show()`, and `application(_:open:)` hands URLs to `FileTranscriptionQueue` and navigates to `.transcribeFile`. Store the URL in `AppState` if the UI is not up yet.
4. `WindowPresenter` (about 60 lines): `applyDockPolicy(menuBarOnly:)`, `show()` (policy `.regular`, then activate, then the openWindow bridge), and a `willClose` observer that restores `.accessory`. It uses the one hidden `OpenWindowBridge` view inside the MenuBarExtra label.
5. `PermissionService`: `mic`/`ax` status, `requestMic()`, `requestAX()`, `openSettings(pane)`, and an async polling loop (1 s, while onboarding is visible or on `didBecomeActive`). Mic + Accessibility only.
6. `OnboardingView`: enum `Step { welcome, permissions, model, shortcut, tryIt }`, persisted in UserDefaults, `.opacity` transitions at 0.22 s, a thin progress indicator. The model step defaults to downloading Parakeet TDT 0.6b v3, with a "Use cloud instead" disclosure (Gemini/Groq + key). There is no AI step, since AI is enabled later in Models.
7. `MainView`: `NavigationSplitView` with a fixed sidebar of Dashboard, History, Transcribe File, Dictionary, Models, Settings. Fixed width of about 900-950, min height 650-750.
8. `SettingsView`: `Form(.grouped)` with about 10 controls: shortcut + mode, cancel key, microphone, language, mute while recording, sounds on/off, keep clipboard + delay, hide Dock icon, launch at login, reset onboarding.
9. `LaunchAtLogin`: `SMAppService.mainApp` register/unregister with status reads off the main actor; the toggle reflects the actual status after the call.
10. `FileTranscriptionQueue` (`@MainActor @Observable`) and `AudioDecoder` (nonisolated): decoding goes through AVAssetReader only, to 16 kHz mono Float32. Items are processed sequentially and each can be cancelled. For local Parakeet, pass samples, or the URL, straight to FluidAudio. For cloud, write a 16k Int16 WAV and upload it. Post-processing uses the same `TextPipeline` as dictation (filter, dictionary replacements, optional AI), and the result is saved to history with `source = .file`.
11. Storage: one SwiftData container in `~/Library/Application Support/VocaType2/` with no CloudKit. A one-time importer for the old `com.prakashjoshipax.VoiceInk/*.store` comes later.
12. Build: XcodeGen `project.yml` (or a hand-made xcodeproj) plus a `Makefile` with `make local` (stable self-signed identity, absolute entitlements path, `ditto` to `~/Applications` or `~/Downloads`, `xattr -cr`) and `make run`. Hardened runtime on, sandbox off, entitlements audio-input + network.client only.
13. Info.plist: `NSMicrophoneUsageDescription`, `CFBundleDocumentTypes` (audio/movie, Alternate), `LSApplicationCategoryType` productivity. `LSUIElement` stays false and the Dock is controlled at runtime.
14. Keep `URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)` at launch, and the launch-time Accessibility-missing banner.

FYI for the migration (read-only check of the user's defaults): the old installations use the domains `com.prakashjoshipax.VoiceInk` (language `pl`, Groq, mute on), `com.dawidkawalec.vocatype` (clipboard restore 2.5 s, RecorderType mini) and `pl.kawalec.VocaType`. The newest one is stuck at `onboardingStage=permissions` (setup local, cloud provider Gemini, AI provider Groq). The data stores are in `~/Library/Application Support/com.prakashjoshipax.VoiceInk/`.

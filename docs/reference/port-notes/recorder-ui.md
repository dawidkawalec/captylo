# Port note: Recorder widget UI (mini + notch)

Source: `<old repo>/VoiceInk` (read-only). The user's config has `RecorderType = mini`
and `showLiveTranscript` left at its default (`true`). Parakeet realtime is on, so the live transcript row matters.

## 1. What it does for the user

Essential (keep):
- A small black pill shows at the bottom-center of the screen while dictating. It never takes focus from the app you are typing into.
- Left: one round record/stop button. Center: a live waveform (15 bars) while recording, flat bars before that.
- After you stop, "Transcribing" (or "Enhancing") shows with animated dots, and the button turns into a spinner.
- Live transcript (realtime Parakeet partials): the pill widens and a 56pt-tall area above the bar shows the partial text, auto-scrolled to the bottom with a fade at the top.
- The panel disappears when the text is delivered (hidden BEFORE the paste), or on cancel or error.
- Escape while the panel is visible: pressing twice within 1.5s cancels. The first press shows the toast "Press Esc again to cancel". Esc is swallowed and never reaches the target app.
- Errors are NOT drawn in the pill. The pill is dismissed and a separate toast panel appears (see section 3.6).

Bloat (DROP):
- Choosing between two styles (notch vs mini). Keep ONE style. The mini is what the user runs. The notch geometry is documented below in case the new design is notch-like.
- Assistant/"respond" mode: `AssistantPanelView`, follow-up TextField, message bubbles, copy buttons, close button, 520pt-wide state.
- `RecorderModeButton` + `ModePopover` (mode switching from the pill, hover popover) and the Option+1..0 mode shortcuts.
- `EnhancementPromptPopover.swift` (dead code, nothing references it).
- `RecorderPanelStyle` persistence, rebuilding the panel on style change, backup import/export of `recorderType`.
- AppIntents `ToggleMiniRecorderIntent`/`DismissMiniRecorderIntent`, which only post notifications (optional, cheap to keep).
- The `showLiveTranscript` toggle: only needed if the user wants to turn it off. Default ON.

## 2. Key files and control flow

| File | Role |
|---|---|
| `Views/Recorder/MiniRecorderPanel.swift` | NSPanel subclass + frame math (bottom center) |
| `Views/Recorder/MiniWindowManager.swift` | Creates the panel once, hosts the SwiftUI view, show = orderFront, hide = orderOut |
| `Views/Recorder/MiniRecorderView.swift` | Pill layout: live transcript row + 40pt control bar |
| `Views/Recorder/NotchRecorderPanel.swift`, `NotchWindowManager.swift`, `NotchRecorderView.swift`, `NotchShape.swift` | Notch variant |
| `Views/Recorder/RecorderComponents.swift` | Record button, spinner, dot progress, LiveTranscriptView, RecorderStatusDisplay |
| `Views/Recorder/AudioVisualizerView.swift` | 15-bar waveform, static bars, "Transcribing" label |
| `Transcription/Engine/RecorderUIManager.swift` | `isRecorderPanelVisible`, toggle/dismiss/cancel logic |
| `Transcription/Engine/RecordingState.swift` | `idle, starting, recording, transcribing, enhancing, busy` |
| `Recorder.swift` (`audioMeterSnapshot`) + `CoreAudioRecorder.swift` (`calculateMeters`) | Audio level source |
| `Shortcuts/RecorderPanelShortcutManager.swift` | Esc double-press while visible (CGEventTap via `ShortcutMonitor`) |
| `Transcription/Engine/TranscriptionDelivery.swift` | Stop sound, then dismiss the panel, then paste |
| `Notifications/NotificationManager.swift` | Error/info toast panel |

Control flow (hotkey or pill button, both call `RecorderUIManager.toggleRecorderPanel()`):
```
not visible          -> playStartSound(); isRecorderPanelVisible = true (didSet -> show()); engine.toggleRecord()
visible + recording  -> engine.toggleRecord()            // stop -> pipeline -> .transcribing -> (.enhancing) -> deliver
visible + starting/transcribing/enhancing -> cancelRecording() (engine.cancel + dismiss)
visible + idle/busy  -> dismissRecorderPanel()
deliver(paste)       -> playStopSound(); await dismiss(); CursorPaster.startPasteAtCursor(text)
any start failure    -> recordingState = .idle; toast(error, 7s, action button); dismiss()
```
`engine.recordingState` and `engine.partialTranscript` are `@Published` on a `@MainActor` ObservableObject
(protocol `RecorderStateProvider`). The view observes the engine. The audio meter is NOT published (see 3.4).

## 3. Exact technical details

### 3.1 Mini panel (the one to port)
```swift
class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // only needed for assistant TextField -> set FALSE in rewrite
    override var canBecomeMain: Bool { true }  // -> FALSE in rewrite
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false                 // commit 3c965ee "Keep recorder panels visible while active" (survives NSApp.hide / Cmd+H)
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true  // draggable, but show() resets the frame every time (position not persisted)
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        titlebarAppearsTransparent = true; titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
}
```
- NOT set anywhere in the codebase: `becomesKeyOnlyIfNeeded`, `ignoresMouseEvents` (an explicit `false` was removed in 3c25245), `acceptsFirstMouse`.
- Frame: host window is 540 x 430 (sized for the assistant panel). x = `visibleFrame.midX - 270`, y = `visibleFrame.minY + 24`.
  Screen = `NSScreen.main`. The SwiftUI pill is bottom-aligned inside the host: `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)`.
  The transparent area of the host lets clicks through only because its pixels are alpha 0 (implicit). The rewrite should size the window to the pill or keep a small host (e.g. 320x120).
- Show: `setFrame(metrics, display: true); orderFrontRegardless()`. It never calls `makeKey`, so the target app keeps key status.
- Hide: `orderOut(nil)`. There is no window-level fade on show or hide: the panel pops in and out.
- The window is created once and reused (commit 0c9fdb0, done for speed). `NSHostingController(rootView:)` becomes `panel.contentView = hc.view`, retained via `NSWindowController`.

### 3.2 Notch panel (reference only)
- `styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow]`, then `styleMask.remove(.titled)`.
- `level = .statusBar + 3`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
  `appearance = NSAppearance(named: .darkAqua)`, `isMovable = false`, `canHide = false`, `hidesOnDeactivate = false`, clear background, no shadow.
- Geometry: `notchHeight = screen.safeAreaInsets.top > 0 ? top : NSStatusBar.system.thickness`,
  `notchWidth = screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width` (fallback 180).
  Host frame: width = notchWidth + (240 + 10) * 2, height 430, x = `frame.midX - w/2`, y = `frame.maxY - 430` (full frame, not visibleFrame).
- Re-frames on `NSApplication.didChangeScreenParametersNotification` after a 0.1s delay.
- The hosting controller subclass sets `view.wantsLayer = true; layer.backgroundColor = clear`.
- Pill sizes: collapsed = notchWidth x 0; active = notchWidth + 90*2 by notchHeight + 6; liveText = notchWidth + 110*2 by (notchHeight + 6) + 57.
  Spring expand `.spring(response: 0.42, dampingFraction: 0.80)`, collapse `.spring(response: 0.45, dampingFraction: 1.0)`.
  Side content fades in with `expandAnimation.delay(0.09)`. The visualizer is squashed by `scaleEffect(y: min(1, (notchHeight - 8) / 25))`.
  `NotchShape`: a quad-curve "ears" top (radius 8, or 12 with live text) and a rounded bottom (16, or 22), with animatable radii.

### 3.3 Pill layout (mini)
- Control bar: height 40, `HStack(spacing: 0)`: record button (leading pad 10), Spacer, `RecorderStatusDisplay`, Spacer, mode button (22pt, trailing 12; DROP it and use a symmetric spacer or timer).
- Width 184 compact, or 300 when the live transcript shows. Corner radius 20 compact, 14 expanded (`RoundedRectangle(style: .continuous)`).
- Background `Color.black`. Divider between the transcript and the bar: `Color.white.opacity(0.15)`.
- The width and radius animate with `.easeInOut(duration: 0.3)` keyed on `hasLiveTranscript`.
- `hasLiveTranscript = showLiveTranscript && state == .recording && !partialTranscript.isEmpty`. The transcript row therefore disappears the moment you stop.

### 3.4 Audio meter + waveform
The audio thread (CoreAudio render callback) computes RMS and peak over the buffer. It stores dB as a Float bit pattern in `ManagedAtomic<UInt32>` (swift-atomics, relaxed ordering), with -160 at reset:
```swift
let rms = sqrt(sum / Float(totalSamples))
let avgDb  = 20.0 * log10(max(rms, 0.000001))
let peakDb = 20.0 * log10(max(peak, 0.000001))
averagePowerBits.store(avgDb.bitPattern, ordering: .relaxed)
```
UI side, `Recorder.audioMeterSnapshot()` runs on the main actor and is called by the view each frame. It normalizes dB from [-60, 0] to [0, 1] linearly, clamped, then applies an EMA `s = s*0.6 + x*0.4` (NSLock-guarded) and returns `AudioMeter(averagePower:peakPower:)`.
Perf fix (commit 576ed67 "reduce recording UI contention"): the meter was a `@Published` value, which re-rendered every observer about 60 times a second. It is now a closure `() -> AudioMeter` PULLED inside `TimelineView`. Keep this pattern.
Caveat: the EMA runs per call, so the smoothing depends on the frame rate, and two views reading it would double-smooth it.

```swift
TimelineView(.animation(minimumInterval: 0.016)) { context in   // ~60 fps
    let audioMeter = audioMeterProvider()
    HStack(spacing: 2) {
        ForEach(0..<15, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(0.85))
                .frame(width: 3, height: barHeight(for: i, at: context.date, audioMeter: audioMeter))
        }
    }
}
// phases[i] = Double(i) * 0.4 ; minH = 4, maxH = 28
func barHeight(for i: Int, at date: Date, audioMeter: AudioMeter) -> CGFloat {
    let t = date.timeIntervalSince1970
    let amplitude = max(0, min(1, pow(audioMeter.averagePower, 0.7)))   // boost quiet speech
    let wave = sin(t * 8 + phases[i]) * 0.5 + 0.5                        // travelling wave
    let centerDistance = abs(Double(i) - 15.0 / 2) / Double(15 / 2)
    let centerBoost = 1.0 - centerDistance * 0.4                          // taller in the middle
    return max(4, 4 + CGFloat(amplitude * wave * centerBoost) * (28 - 4))
}
```
- `StaticVisualizer` (idle/starting): 15 bars, 3x4pt, `white.opacity(0.5)`.
- `ProcessingStatusDisplay` (transcribing/enhancing): a 11pt medium "Transcribing"/"Enhancing" label above 5 dots (3pt, spacing 2), driven by a `Timer` every 0.18s (transcribing) or 0.22s (enhancing). A dot is lit (0.85 opacity, otherwise 0.25) when `index <= currentDot`. The cycle is `(d+1) % 7`, with values over 5 mapped to -1. The frame is fixed at height 28 so the layout does not jump.
- Status switch: `.transition(.opacity)` plus `.animation(.easeInOut(duration: 0.2), value: currentState)`.

### 3.5 Record button
- A 21x21 circle with a 0.6pt strokeBorder, `.buttonStyle(.plain)`, `.contentShape(Circle())`, `.animation(.easeOut(duration: 0.16), value: visualState)`.
- ready (idle/starting/busy): surface rgb(0.30,0.30,0.32), border rgb(0.42,0.42,0.44), an 8x8 rounded square mark (radius 2.2), rgb(0.78,0.78,0.80).
- recording: surface `systemRed.opacity(0.92)`, border `systemRed.opacity(0.98)`, white mark.
- processing (transcribing/enhancing): surface `white.opacity(0.13)`, border `white.opacity(0.18)`, and a spinner `Circle().trim(0.1...0.9)`, 12x12, lineWidth 1.5, rotating 360 degrees with `.linear(duration: 1).repeatForever(autoreverses: false)`.
- Disabled in starting/transcribing/enhancing/busy. It has `.help` and `accessibilityLabel` ("Start recording" / "Stop recording" / ...).

### 3.6 Live transcript view
```swift
ScrollViewReader { proxy in
    ScrollView(.vertical, showsIndicators: false) {
        Text(text).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6).id("bottom")
    }
    .frame(height: 56)
    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                 .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
    .onChange(of: text) { proxy.scrollTo("bottom", anchor: .bottom) }
}
.transaction { $0.disablesAnimations = true }   // partials arrive fast; animating each one janks
```
The engine guards stale partials: it sets `partialTranscript` only if `activeRecordingStartID == startID && recordingState == .recording`.
The partial callback hops with `Task { @MainActor in ... }`.

### 3.7 Errors / toast (separate window, not in the pill)
- A new `NSPanel(styleMask: [.borderless, .nonactivatingPanel])` per toast, with `isFloatingPanel`, `level = .mainMenu`, clear background, no shadow. Its size is `hostingController.view.fittingSize`.
- Position: `visibleFrame.midX`, y = `visibleFrame.minY + 24 + 34 + 16` (just above where the pill sits). Screen = `NSApp.keyWindow?.screen ?? NSScreen.main`.
- It calls `makeKeyAndOrderFront`. That is harmless because a borderless NSPanel's default `canBecomeKey` is false. Do NOT override it to true.
- Fades in over 0.3s easeOut (`animator().alphaValue`) and out over 0.2s easeIn, then `close()`. Default duration 3s; errors 7s with an optional action button. Error toasts play the "esc" sound.
- Content: an SF Symbol icon (`xmark.octagon.fill` for error), a 12pt medium white title, up to 2 lines, an optional action button and a close "xmark".

### 3.8 Not stealing focus (summary of what actually makes it work)
1. `.nonactivatingPanel`: clicking the pill never activates the app, so the target app stays frontmost.
2. Show uses `orderFrontRegardless()`, never `makeKeyAndOrderFront`/`NSApp.activate`.
3. Hide happens BEFORE the paste (`await actions.dismiss()` then `CursorPaster.startPasteAtCursor`). If the pill had become key through a click, ordering it out returns key status to the target window before Cmd+V is posted.
4. The old `canBecomeKey = true` exists only for the assistant TextField. In the rewrite, return `false` so a button click cannot take key status at all.
   `NSButton`/SwiftUI `Button` in a non-key nonactivating panel still receives clicks. Verify first-click works; if not, add `acceptsFirstMouse` in an NSHostingView subclass.
5. Esc is intercepted by a session-level `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, mask: keyDown|keyUp|flagsChanged)`. It is installed only while the panel is visible and returns `nil` for matched events (suppresses them).
   The tap is re-enabled on `tapDisabledByTimeout`/`tapDisabledByUserInput`. It needs Accessibility/Input Monitoring permission. It is started and stopped by observing `$isRecorderPanelVisible.values`.

### 3.9 Sounds (triggered from UI manager / delivery)
`playStartSound()` plays before the panel shows, on the toggle into recording. `playStopSound()` plays right before dismiss on delivery. `playEscSound()` plays on error toasts.

## 4. Known quirks worth not repeating
- The 540x430 invisible host (mini) and the 430pt-tall invisible host (notch) exist only for the assistant panel. The rewrite can drop them.
- `NSScreen.main` is the screen with the key window. With multiple monitors the pill can appear on the "wrong" screen. Prefer the screen containing `NSEvent.mouseLocation` (or the frontmost app's window).
- Dragging the mini panel is pointless because `show()` resets the frame. Either persist the dragged origin or set `isMovable = false`.
- The notch collapse spring is never visible, because `hide()` calls `orderOut` immediately. To animate out, animate state to collapsed and call `orderOut` in the completion.
- Style switching destroys the window and re-shows it after `Task.sleep(50ms)`. This goes away with a single style.

## 5. Recommended minimal design for the rewrite
- `enum DictationPhase { case idle, recording, transcribing, enhancing }`, plus an `error(String)` shown by a toast, never inside the pill. Drop `starting`/`busy` from the UI (map them to idle/processing).
- `@MainActor @Observable final class DictationController`: owns `phase`, `partialText`, and `toggle()`/`cancel()`. It is the single source of truth, and the hotkey, the pill button and Esc all call into it.
- `final class RecorderPanel: NSPanel`: `[.nonactivatingPanel, .borderless/.fullSizeContentView]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`, `canHide = false`, `hidesOnDeactivate = false`, `canBecomeKey = false`, `canBecomeMain = false`, clear, no shadow (draw the shadow in SwiftUI if wanted).
- `@MainActor final class RecorderPanelController`: creates the panel ONCE at launch (so the first show is instant), positions it at bottom-center of the active screen (`visibleFrame.minY + 24`), and shows/hides with `orderFrontRegardless`/`orderOut`. An optional 0.15s alpha fade goes through `NSAnimationContext`, with `orderOut` in the completion.
- `struct RecorderPillView`: 40pt black capsule; button left, status center; width 184 (up to 300 with live text); `.easeInOut(0.3)` on the width change. Its content switches on `phase` with an opacity transition.
- `struct WaveformView`: `TimelineView(.animation(minimumInterval: 1/60))`, 15 bars 3x(4...28), keeping the formula above. It reads a `LevelMeter` via a closure/`Sendable` getter, never an observed property.
- `final class LevelMeter: Sendable`: the audio thread writes RMS dB atomically (`Atomic<UInt32>` from Synchronization on macOS 15, or `OSAllocatedUnfairLock`). The UI reads it, normalizes -60..0 dB, and applies a time-based EMA (alpha derived from the dt between frames).
- `struct LiveTranscriptView`: copy 3.6 as is (56pt, top fade mask, scroll to bottom, animations disabled). Shown only while `phase == .recording && !partialText.isEmpty`.
- `ToastPanel`: one reusable borderless nonactivating panel, `level = .mainMenu`, above the pill, 3s default and 7s for errors, fade 0.3/0.2.
- `EscapeCancelMonitor`: a CGEventTap active only while the pill is visible, with Esc double-press within 1.5s to cancel and the Esc event swallowed. Reuse the global hotkey tap if the shortcut subsystem already has one.
- Delivery order: stop sound, then hide the pill, then paste (CGEvent Cmd+V), and never the reverse.
- Skip the notch variant for v2.0. If it is wanted later, reuse 3.2 (auxiliaryTopLeft/RightArea math, `.statusBar + 3`, NotchShape).

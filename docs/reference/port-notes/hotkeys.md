# Port note: Global hotkeys / shortcuts

Source: `<old repo>/VoiceInk/Shortcuts/*` (about 2.7k lines) plus `AppIntents/*`,
`Transcription/Engine/RecorderUIManager.swift` (toggle/cancel entry points), `Views/Settings/SettingsView.swift` (UI).
No unit tests exist for this subsystem.

## 1. What it does for the user

Essential (KEEP):
- **One global recording shortcut** that works in every app, including **modifier-only keys**
  (Fn/Globe, Right Option, Right Command, Right Ctrl, Right Shift, any side-specific single modifier)
  and regular combos (for example `⌃⌥Space`, `F13`).
- **Three activation behaviours**. The default is **Hybrid**, and it is the one to ship:
  - press and hold >= 0.5 s, then release = push-to-talk (stops on release)
  - short tap (< 0.5 s) = latches "hands-free". Recording keeps going and the next press stops it.
  - Toggle: press = start, next press = stop. Release is ignored.
  - Push-to-talk: press = start, release = stop.
- **Escape to cancel** while the recorder panel is visible. The first Esc shows a toast "Press Esc again to cancel".
  A second Esc within 1.5 s cancels and discards the recording.
- **Accidental-start guard**. If another (non-modifier) key goes down within 1.0 s of the hotkey press
  (for example Right Option + `a` = `ą` on a Polish keyboard, or Right Cmd + C), a recording that
  this press just started is cancelled. **This is critical for this user.**
- **Shortcut recorder** control in Settings/Onboarding. It captures the next keypress or modifier-only chord and
  validates it (it must contain a modifier and must not be a reserved system shortcut).
- Hotkey is ignored while the pipeline is transcribing, enhancing or busy.

Real user data: the installed daily-driver app (`/Applications/VocaType.app`, bundle `com.dawidkawalec.vocatype` v1.64,
an older build) stores `selectedHotkey1 = rightOption` and no `hotkeyMode1`, so it uses the default (hybrid).
The current source build (`pl.kawalec.VocaType`) has `Shortcut_primaryRecording_cleared = 1`, so onboarding never finished.
**Default for the rewrite: Right Option, hybrid.** Offer Fn and Right Command as one-click presets.

DROP (bloat):
- Secondary recording shortcut (`secondaryRecording`) and its own mode.
- Per-"Mode" shortcuts (`ModeShortcutManager`, `.mode(UUID)`) and in-panel `⌥1..⌥0` mode switching.
- Utility shortcuts: paste last enhancement, retry last transcription, open history window, quick-add to dictionary.
  "Paste last transcription" is the only one worth a later optional add.
- Middle-mouse-button toggle (global `NSEvent` monitor on `.otherMouseDown` with `buttonNumber == 2` and a 200 ms hold delay).
- Custom "cancel recorder" shortcut that replaces Esc (with its "reset to default" UI).
- The whole `ShortcutMigration.swift` (KeyboardShortcuts-lib legacy keys, `selectedHotkey1/2`, `hotkeyMode1/2`).
  Replace it with a one-shot import of `selectedHotkey1` (see section 3.9).
- Toggle/PTT/Hybrid picker. Consider shipping Hybrid only (it already covers both PTT and toggle).
- Assistant "follow-up" branch in `toggleRecorderPanel` (idle + visible + `canSendFollowUp`).

## 2. Key files and control flow

| File | Role |
|---|---|
| `Shortcuts/Shortcut.swift` | Value type `{kind: key/modifierOnly, keyCode, modifierFlags}`, matching, normalization, display names (UCKeyTranslate) |
| `Shortcuts/ShortcutMonitor.swift` | **One CGEventTap** per instance. Tracks down/up state per action, interruption detection, dispatches callbacks to main |
| `Shortcuts/RecordingShortcutManager.swift` | Owns the global monitor + `RecordingShortcutModeHandler` (toggle/PTT/hybrid state machine, cooldown, accidental-start cancel) |
| `Shortcuts/RecorderPanelShortcutManager.swift` | **Second CGEventTap**, alive only while the recorder panel is visible: Esc double-press cancel, ⌥digits |
| `Shortcuts/ShortcutRecorder.swift` | SwiftUI recorder button + `ShortcutRecorderModel` (local `NSEvent` monitor) |
| `Shortcuts/ShortcutValidator.swift` | Rules + reserved list + conflict check |
| `Shortcuts/ShortcutStore.swift` | UserDefaults JSON persistence, `shortcutDidChange` notification |
| `AppIntents/*.swift` | `ToggleMiniRecorderIntent`, `DismissMiniRecorderIntent`, `AppShortcutsProvider` |
| `Transcription/Engine/RecorderUIManager.swift` | `toggleRecorderPanel()`, `cancelRecording()`, notification handlers used by intents |

Flow:
```
CGEventTap callback (main run loop)
  -> ShortcutMonitor.handleEvent(kind, keyCode, flags)
       keyDown & non-modifier key -> handleShortcutInterruptions (<= 1.0s since press) -> onShortcutInterrupted
       modifier-only shortcuts: only flagsChanged matters (match -> down, same keyCode again -> up)
       key shortcuts: keyDown match -> down (suppress), autorepeat -> suppress, keyUp/flags drop -> up (suppress)
  -> DispatchQueue.main.async -> Task { @MainActor } -> RecordingShortcutModeHandler.handleKeyDown/Up/Interruption
  -> RecorderUIManager.toggleRecorderPanel() / cancelRecording()
       hidden  -> play start sound, show panel, engine.toggleRecord()  (start)
       visible -> state .recording -> engine.toggleRecord() (stop + transcribe + paste)
                  state .starting/.transcribing/.enhancing -> cancelRecording()
                  state .idle/.busy -> dismiss panel
```
The monitor starts 100 ms after `RecordingShortcutManager.init`. It restarts on every `ShortcutStore.shortcutDidChange`
(full `stop()` then `start()`, which also resets the mode-handler state).

## 3. Details that are easy to get wrong

### 3.1 Event tap (not NSEvent monitors, not the KeyboardShortcuts lib)
- Commit `d3d55af` "Add unified shortcut handling" removed the KeyboardShortcuts SPM package and the old
  `NSEvent.addGlobalMonitorForEvents(.flagsChanged)` + local monitor approach, replacing both with one `CGEventTap`.
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown|keyUp|flagsChanged, ...)`.
  `.defaultTap` (active) is required so combo shortcuts can be **suppressed** (return `nil`) and never reach the focused app.
- The run-loop source is added to `CFRunLoopGetMain()` in `.commonModes`, so the callback runs **on the main thread**.
  Risk: if main is blocked, system-wide typing lags and macOS disables the tap with `.tapDisabledByTimeout`.
- On `.tapDisabledByTimeout` / `.tapDisabledByUserInput`: re-enable with `CGEvent.tapEnable(tap:enable:true)` **and**
  synthesize key-up for every shortcut currently "down". Otherwise PTT gets stuck recording forever.
- Event time uses `ProcessInfo.processInfo.systemUptime`, not `event.timestamp`.
- Flags conversion: `NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))`. The device-independent bits are identical
  (shift 1<<17, control 1<<18, option 1<<19, command 1<<20, numericPad 1<<21, function/secondaryFn 1<<23).
  Normalize to `[.control, .option, .shift, .command, .function]` before comparing.
- Modifier-only shortcuts are **not suppressed**, so the Right Option / Fn event still reaches apps. Combo shortcuts are
  suppressed on keyDown, on autorepeat keyDowns and on keyUp.

### 3.2 Key codes (Carbon `kVK_*`)
Fn `0x3F` (63), Right Option `0x3D` (61), Left Option `0x3A` (58), Right Command `0x36` (54), Left Command `0x37` (55),
Right Control `0x3E` (62), Left Control `0x3B` (59), Right Shift `0x3C` (60), Left Shift `0x38` (56), Escape `0x35` (53).
Side detection uses the **keyCode of the flagsChanged event**. An alternative is the device-dependent low flag bits
(`NX_DEVICERALTKEYMASK 0x40`, `NX_DEVICELALTKEYMASK 0x20`, `NX_DEVICERCMDKEYMASK 0x10`, `NX_DEVICELCMDKEYMASK 0x08`).

### 3.3 Modifier-only matching rules (see excerpt 4.2)
- A single side-specific modifier is stored with its keyCode. A multi-modifier chord (for example `⌃⌥`) is stored with
  a generic keyCode of `UInt16.max`.
- Press = flagsChanged with the **same keyCode** and normalized flags **exactly equal** to the stored flags.
  Commit `11c156f` changed `isSuperset` to `==` to "Fix Fn shortcut triggering during synthetic arrow chords".
  Arrow and F keys carry the `.function` flag, and tools that post synthetic chords produced false Fn presses.
  Exact equality also means Right Option does not fire while Shift is held.
- Release (side-specific) = the next flagsChanged with the same keyCode while down. Flags are not checked.
  Release (generic chord) = flags stop being a superset of the stored flags.
- F1-F20: `.function` is stripped from flags for those key codes (Mac keyboards always set it), so `F13` stays `F13`.
- The older HotkeyManager had a 75 ms debounce on Fn flag changes. Commit `eab3e10` fixed a CancellationError in that
  debounce (Toggle mode). The new code dropped the debounce in favour of exact-flag matching.
- Fn/Globe caveat (general macOS behaviour, not handled in code): if System Settings > Keyboard > "Press Globe key to" is
  not "Do Nothing", Fn also opens the emoji picker, switches input source or starts dictation. Onboarding should tell
  the user this when they pick Fn.

### 3.4 Mode state machine (`RecordingShortcutModeHandler`)
- `shortcutPressCooldown = 0.5 s`: any keyDown within 0.5 s of the previous accepted keyDown is ignored
  (wall-clock `Date()`). Side effect: quick start-then-stop taps inside 0.5 s are dropped. Double-tap gestures are impossible.
- `hybridPressThreshold = 0.5 s`: on key-up, if held >= 0.5 s **and** state == `.recording`, stop. Otherwise latch hands-free.
- `isShortcutPressed` + `activeRecordingShortcutAction` stop duplicate downs and ups coming from the wrong action.
- `canHandleShortcutAction` = state not in {transcribing, enhancing, busy}.
- There is **no double-tap logic** for recording. Hands-free is only the hybrid/toggle latch.

### 3.5 Accidental-start cancel (interruption)
- In the monitor: on any keyDown whose keyCode is **not** a modifier key, for each "interruptible" action that is down,
  pressed <= `shortcutInterruptionWindow = 1.0 s` ago and not yet interrupted, where modifier-only shortcuts are always
  interrupted and key shortcuts only by a different keyCode: mark it interrupted and fire `onShortcutInterrupted`.
- In the handler: when the press began while the panel was hidden and state `.idle` (`activeShortcutCanCancelAccidentalStart`),
  call `reset()` then `cancelRecording()`. If the interruption arrives before the keyDown Task runs (a race across the two
  async hops), the action is put in `interruptedRecordingActions` and the next keyDown for it is swallowed.
- UX cost: the recording **starts immediately** on press, with sound and panel, and is cancelled afterwards, so the user sees a flash.

### 3.6 Escape handling (`RecorderPanelShortcutManager`)
- A second `ShortcutMonitor` (a second event tap) runs only while `isRecorderPanelVisible` (it observes `$isRecorderPanelVisible.values`).
- It registers `Esc` with no modifiers as a key shortcut, so **Esc is suppressed system-wide while the panel is visible**.
- Double-press: first press stores the time and shows a toast lasting 1.5 s. A second press within `escapeDoublePressThreshold = 1.5 s`
  calls `cancelRecording()`. A Task clears the first-press time after 1.5 s.

### 3.7 Permissions
- An active keyboard event tap needs **Accessibility** (`AXIsProcessTrusted()`). This is the same permission the Cmd+V paste needs,
  so one grant covers both. App **must not be sandboxed** (`com.apple.security.app-sandbox = false`).
- Commit `c28b755` removed an Input Monitoring gate (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`).
  The app now relies on Accessibility only. Failure is only logged (`accessibilityTrusted=..., listenEventAccess=...`).
- Prompt: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`, then open
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and poll `AXIsProcessTrusted()`.
- **Gap:** `tapCreate` returns nil without permission, and nothing retries after the user grants it. Onboarding only works
  because recording a shortcut posts `shortcutDidChange`, which restarts the tap. The rewrite should retry installing the
  tap when AX flips to trusted (poll or on `NSApplication.didBecomeActive`).
- Dev gotcha (general macOS): TCC ties the grant to the code signature. Ad-hoc rebuilds silently lose trust, so sign
  with a stable Apple Development identity.

### 3.8 Shortcut recorder UI
- Uses `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`, which only works while the app window is key.
  It returns `nil` to consume the event.
- **When recording starts it clears the stored shortcut first** (`ShortcutStore.setShortcut(nil)` then restart the tap).
  Otherwise the global tap suppresses the current combo before the local monitor ever sees it.
- Plain Esc cancels recording. A non-modifier keyDown finishes immediately as `.key(keyCode, normalizedFlags)`.
- Modifier-only capture: on each flagsChanged, OR the flags into `peakModifierFlags` and preview. When the flags become
  empty (all released), finish with the pending modifier-only shortcut. With exactly one modifier the side-specific keyCode is kept.
- Only one recorder can be active: starting one posts a notification that cancels any other.
- Validation (`ShortcutValidator`): modifier-only needs non-empty flags. A key shortcut needs >= 1 modifier unless it is F1-F20.
  Shift + typing key is rejected. A reserved list is rejected: ⌘A C F H M N O P Q S T V W X Z ,; ⌥⌘H/M/W/Esc; ⇧⌘Z; ⌥⇧⌘V;
  ⌃⌘Q ⇧⌘Q ⌥⇧⌘Q; ⌘B I U; ⌃⌘D; ⌥Delete. ⌘G was removed from the list in `db6be05`.
- Display: modifier glyphs `⌃ ⌥ ⇧ ⌘ Fn`, side names like "Right ⌥", key names through `UCKeyTranslate` on the current layout
  (`TISCopyCurrentKeyboardInputSource`), with a QWERTY fallback table.

### 3.9 Persistence
- `UserDefaults["Shortcut_primaryRecording"]` = JSON `{"kind":"modifierOnly","keyCode":61,"modifierFlagsRawValue":524288}`.
  `"Shortcut_primaryRecording_cleared" = true` marks an explicit clear. `primaryRecordingShortcutMode` = `"hybrid" | "toggle" | "pushToTalk"`.
- Import from the user's live app: `defaults read com.dawidkawalec.vocatype selectedHotkey1` returns `rightOption`.
  Preset map: rightOption 0x3D [.option], leftOption 0x3A, leftControl 0x3B, rightControl 0x3E [.control],
  fn 0x3F [.function], rightCommand 0x36 [.command], rightShift 0x3C [.shift].

### 3.10 App Intents
- Two `AppIntent`s with `openAppWhenRun = false`, whose `perform()` (on `@MainActor`) posts `.toggleRecorderPanel` / `.dismissRecorderPanel`
  to NotificationCenter. `AppShortcutsProvider` phrases use `\(.applicationName)`. `AppShortcuts.updateAppShortcutParameters()`
  is called at launch. Dismiss = cancel if starting, recording, transcribing or enhancing, otherwise hide the panel.
  Worth keeping (about 40 lines) for Shortcuts.app, Stream Deck and Raycast.

### 3.11 Self-trigger hazard
`CursorPaster` posts Left Cmd (`0x37`) flagsChanged + V through `.cghidEventTap` with `CGEventSource(stateID: .privateState)`.
The tap sees these synthetic events. With Left ⌘ as the hotkey, pasting would re-trigger it. The rewrite should tag its own
events (`event.setIntegerValueField(.eventSourceUserData, value: MAGIC)`) and ignore them in the tap.

## 4. Code excerpts

### 4.1 Tap install + disable recovery (`ShortcutMonitor.swift`)
```swift
let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.resetPressedShortcutsAfterTapInterruption()   // fires keyUp for all pressed
        if let eventTap = monitor.eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}
guard let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: Self.eventMask,   // keyDown | keyUp | flagsChanged
        callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
else { return false }   // no Accessibility -> nil
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
// stop(): CFRunLoopRemoveSource(...) then CFMachPortInvalidate(eventTap)
```

### 4.2 Modifier-only match/release (`Shortcut.swift` + monitor)
```swift
func matchesModifierEvent(keyCode ev: UInt16, modifierFlags f: NSEvent.ModifierFlags) -> Bool {
    guard kind == .modifierOnly else { return false }
    let n = Self.normalizedModifierFlags(f, forKeyCode: ev)
    if keyCode == Self.genericModifierKeyCode { return n == modifierFlags }
    return keyCode == ev && n == modifierFlags          // exact, NOT isSuperset (fn/arrow bug)
}
func shouldReleaseModifierEvent(keyCode ev: UInt16, modifierFlags f: NSEvent.ModifierFlags) -> Bool {
    guard kind == .modifierOnly else { return false }
    let n = Self.normalizedModifierFlags(f, forKeyCode: ev)
    if keyCode == Self.genericModifierKeyCode { return !n.isSuperset(of: modifierFlags) }
    return keyCode == ev                                 // same physical key changed again => up
}
// key shortcut on flagsChanged while down: flags still superset -> suppress, else -> keyUp
```

### 4.3 Hybrid/Toggle/PTT handler (`RecordingShortcutManager.swift`, condensed)
```swift
func handleKeyDown(action:, eventTime:, mode:) async {
    if interruptedRecordingActions.remove(action) != nil { return }
    if let last = lastShortcutPressTime, Date().timeIntervalSince(last) < 0.5 { return }
    guard !isShortcutPressed else { return }
    isShortcutPressed = true; activeRecordingShortcutAction = action
    activeShortcutCanCancelAccidentalStart = !isRecorderVisible() && recordingState() == .idle
    lastShortcutPressTime = Date(); shortcutPressStartTime = eventTime
    switch mode {
    case .toggle, .hybrid:
        if isHandsFreeRecording { isHandsFreeRecording = false
            guard canHandle() else { return }; await toggleRecorderPanel(); return }
        if !isRecorderVisible() { guard canHandle() else { return }; await toggleRecorderPanel() }
    case .pushToTalk:
        if !isRecorderVisible() { guard canHandle() else { return }; await toggleRecorderPanel() }
    }
}
func handleKeyUp(action:, eventTime:, mode:) async {
    guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
    isShortcutPressed = false; activeRecordingShortcutAction = nil
    switch mode {
    case .toggle: isHandsFreeRecording = true
    case .pushToTalk: if isRecorderVisible() { guard canHandle() else { return }; await toggleRecorderPanel() }
    case .hybrid:
        let held = shortcutPressStartTime.map { eventTime - $0 } ?? 0
        if held >= 0.5 && recordingState() == .recording { guard canHandle() else { return }; await toggleRecorderPanel() }
        else { isHandsFreeRecording = true }
    }
    shortcutPressStartTime = nil
}
func handleInterruption(action:) async {
    guard isShortcutPressed, activeRecordingShortcutAction == action else {
        if !isRecorderVisible() && recordingState() == .idle { interruptedRecordingActions.insert(action) }
        return
    }
    guard activeShortcutCanCancelAccidentalStart else { return }
    reset(); await cancelRecording()
}
```

### 4.4 Modifier-only capture in the recorder (`ShortcutRecorder.swift`)
```swift
private func handleFlagsChanged(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let modifiers = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode)
    if modifiers.isEmpty, Shortcut.isFunctionKeyCode(keyCode),
       Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil).contains(.function) { return true }
    if !modifiers.isEmpty {
        peakModifierFlags.formUnion(modifiers)
        let single = Shortcut.modifierKeyCodeForSingleModifierEvent(keyCode: keyCode, modifiers: peakModifierFlags)
        let s = Shortcut.modifierOnly(keyCode: single, modifierFlags: peakModifierFlags) // nil keyCode -> generic
        pendingModifierShortcut = s; previewShortcut = s
        return true
    }
    if let pendingModifierShortcut { finish(with: pendingModifierShortcut) }   // all modifiers released
    return true
}
```

## 5. Recommended minimal design for the rewrite

1. `struct Hotkey: Codable, Equatable { enum Kind { key, modifierOnly }; keyCode: UInt16; flags: UInt }`, with the same
   matching semantics as 4.2 (exact flags on press, same keyCode on release, strip `.function` for F-keys). Presets:
   `.rightOption` (default), `.fn`, `.rightCommand`.
2. `final class HotkeyTap` (about 150 lines): **one** CGEventTap for keyDown/keyUp/flagsChanged, installed on a **dedicated
   background thread with its own CFRunLoop** so a busy main thread cannot stall system typing. It emits a small
   `enum HotkeyEvent { down, up, interrupted, escape }` through an `AsyncStream` or a main-actor callback.
   The callback does only integer compares.
3. Handle Esc inside the same tap: suppress and emit `.escape` only when an `isRecorderActive` flag (an atomic or a
   lock-protected Bool set from the main actor) is true. No second tap.
4. Ignore self-posted events: tag the paster's CGEvents via `.eventSourceUserData` and skip them in the tap.
5. `@MainActor final class HotkeyController`: the hybrid state machine from 4.3. Constants: `holdThreshold 0.5`,
   `cooldown 0.5` (consider 0.25), `interruptWindow 1.0`, `escDoubleWindow 1.5`. It talks to one
   `RecorderCoordinator` protocol: `start()`, `stop()`, `cancel()`, `state`.
6. Keep the accidental-start cancel (Polish Right Option diacritics). Optionally defer the start sound and panel reveal
   by about 150 ms while audio capture begins immediately, so a cancelled press does not flash.
7. On tap-disabled events: re-enable and synthesize `.up` (never leave PTT stuck).
8. `PermissionWatcher`: install the tap only when `AXIsProcessTrusted()`. Poll every 1 s (or on app activation) until trusted,
   then install. Show a single "Grant Accessibility" row in onboarding and settings.
9. `HotkeyRecorderView` (SwiftUI + local NSEvent monitor): pause the global tap while recording, handle Esc = cancel,
   capture modifier-only chords on release using peak flags, use a compact validator (modifier required unless F-key,
   no Shift+typing key, small reserved list).
10. Persist as a single UserDefaults JSON key `hotkey` (+ `hotkeyMode` only if the picker is kept). On first launch import
    `selectedHotkey1` from the `com.dawidkawalec.vocatype` domain.
11. Two App Intents (Toggle, Cancel) that call the coordinator directly (no NotificationCenter hop), plus an
    `AppShortcutsProvider`.
12. Fn onboarding hint: link to Keyboard settings and advise "Press Globe key to: Do Nothing".

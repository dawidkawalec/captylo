# Port note: TEXT OUTPUT / PASTE

Source analysed: `<old repo>/VoiceInk` (VoiceInk fork, v2.11).
Scope: how the final transcript ends up at the user's cursor.

## 1. What it does for the user

Essential (keep):
- After a recording finishes, the final text (trimmed, dictionary replacements applied,
  plus an optional trailing space) is **pasted into whatever app/field has focus**, using
  the general pasteboard plus a synthetic Cmd+V.
- **Clipboard restore** (default ON, 2.0 s): the user's previous clipboard comes back after
  the paste, so dictation does not clobber what they had copied. When OFF, the transcript
  stays on the clipboard.
- **Trailing space** (`AppendTrailingSpace`, default ON): appends `" "` so the next
  dictation does not glue onto the previous one.
- **Accessibility permission** is needed for synthetic key events. The app checks
  `AXIsProcessTrusted()`, prompts during onboarding, and shows a launch warning with an
  "Open Settings" deep link.
- **Auto-send** (per mode, default `none`): press Return / Shift+Return / Cmd+Return
  0.5 s after the paste (chat apps).
- **Paste last transcription** hotkey and **Copy last transcription** (history / menu).
- Clipboard-manager etiquette: writes `org.nspasteboard.*` markers so Maccy/Raycast/Paste
  do not record transient transcripts.

Current user setup (from `defaults read pl.kawalec.VocaType`): `pasteMethod = default`
(CGEvent), restore and trailing space at their defaults (ON, 2.0 s, ON), keyboard layout
**Polish Pro** (QWERTY, so the fixed V key code 0x09 works).

Bloat to DROP:
- `ModeOutputMode.respond` (assistant answers inside the recorder) and `.customCommand`
  (runs a shell command with the transcript, 10 s timeout). Just paste.
- `PasteMethod` enum, the legacy `useAppleScriptPaste` migration, and AppleScript paste
  altogether (see section 3.4 for a layout-safe CGEvent that replaces it).
- The restore-delay picker (250 ms to 5 s). Hardcode it, or at most offer an on/off toggle.
- The "Paste last enhancement" variant (AI enhancement is off anyway), license
  "usage restriction" text prepended to the output (`deliverableText`), and the
  Backup/Import/SystemInfo plumbing for the paste settings.
- Per-mode auto-send. Make it one global setting (or drop it for v1).
- `ClipboardMessageModifier` SwiftUI overlay (it is only a "Copied" toast).

Not present in the old code: a "no focused text field, so copy only" fallback. The old
app always posts Cmd+V, even with nothing focused. A failed paste (no AX permission)
still restores the old clipboard after the delay, so the transcript is **lost from the
clipboard** (it only survives in history). The rewrite should fix this (section 5).

## 2. Key files and control flow

| File | Role |
|---|---|
| `Paste/CursorPaster.swift` (246 l) | paste session: snapshot, write, Cmd+V, scheduled restore, auto-send |
| `Paste/ClipboardManager.swift` (76 l) | pasteboard write with marker types; copy helper |
| `Paste/PasteMethod.swift` (45 l) | `default` (CGEvent) vs `appleScript` (DROP) |
| `Transcription/Engine/TranscriptionDelivery.swift` | `paste(...)`: trailing space, stop sound, dismiss panel, paste, auto-send |
| `Transcription/Engine/TranscriptionPipeline.swift` | produces `finalText` (filter, trim, word replacements, optional AI) then calls `delivery.deliver` |
| `Services/LastTranscriptionService.swift` | paste/copy last transcription (0.15 s delay before paste) |
| `Modes/ModeConfig.swift` | `AutoSendKey`, `ModeOutputMode` enums |
| `AppDefaults.swift` | defaults: `restoreClipboardAfterPaste=true`, `clipboardRestoreDelay=2.0`, `AppendTrailingSpace=true` |
| `Views/Recorder/MiniRecorderPanel.swift` | non-activating recorder panel (why focus stays in the target app) |

Flow when recording stops (all on `@MainActor`):

1. Pipeline: `text = TranscriptionOutputFilter.filter(text)` →
   `text.trimmingCharacters(in: .whitespacesAndNewlines)` → dictionary replacements →
   (AI enhancement, off for this user) → `finalText`.
2. `TranscriptionDelivery.deliver`: only if `transcriptionStatus == completed`. Otherwise
   it just dismisses (failed transcriptions are **not** pasted).
3. `paste()`: `pastedText = text + (AppendTrailingSpace ? " " : "")` → play stop sound →
   `await dismiss()` (the recorder panel gets `orderOut(nil)`) → `CursorPaster.startPasteAtCursor`.
4. `performPasteSession`:
   a. If restore is ON: snapshot every pasteboard item and every type as `Data`.
   b. `clearContents()`, write the text as `.string`, plus the markers and a session UUID.
   c. Wait **100 ms** (`prePasteDelay`).
   d. Post Cmd+V (CGEvent, 4 events with **10 ms** gaps between them).
   e. If restore is ON: after `max(clipboardRestoreDelay, 0.25)` s (default **2.0 s**),
      restore only if the pasteboard still holds our text **and** our session UUID.
5. When the paste task finishes, if auto-send is enabled: sleep **500 ms**, then post Return
   (with Shift or Cmd flags as configured).
6. Transcript saved to SwiftData and stats recorded (after `deliver` returns).

Realtime transcription does **not** type incrementally. It only drives the live preview in
the recorder, and the single paste happens at the end.

## 3. Exact technical details

### 3.1 CGEvent Cmd+V
- Event source: `CGEventSource(stateID: .privateState)`. **Not** `.hidSystemState`:
  commit cbf7f60 notes that hidSystemState stamped events with the live keyboard and
  modifier state, which made 0x09 misfire on non-QWERTY layouts. A private state also keeps
  physically held modifiers (for example the dictation hotkey) out of the events.
- Key codes: `0x37` = kVK_Command, `0x09` = kVK_ANSI_V (a *physical* key position),
  `0x24` = kVK_Return.
- Flags: `.maskCommand` set explicitly on cmdDown, vDown and vUp (cmdUp has no flags).
- Tap: `.post(tap: .cghidEventTap)`.
- Order: cmdDown → 10 ms → vDown → 10 ms → vUp → 10 ms → cmdUp. The gaps were added in
  caca8c4 ("Improve clipboard paste reliability"). Earlier versions posted all four
  back-to-back.
- Guard: `AXIsProcessTrusted()` before posting. Without it the events are silently dropped.
- Our own global shortcut CGEventTap (`.cgSessionEventTap`, `.headInsertEventTap`,
  `.defaultTap`) sees these synthetic events too. It does not filter them, which is fine as
  long as Cmd+V is not a bound hotkey. It re-enables itself on
  `tapDisabledByTimeout/UserInput`.

### 3.2 Pasteboard write (`ClipboardManager.setClipboard`)
```
clearContents()
setString(text, .string)                       // fail → abort paste
setString(Bundle.main.bundleIdentifier, "org.nspasteboard.source")
if transient (restore ON):
    setData(Data(), "org.nspasteboard.TransientType")
    setData(Data(), "org.nspasteboard.AutoGeneratedType")
if sessionID: setString(uuid, "pl.kawalec.VocaType.PasteSession")
return string(forType: .string) == text        // read-back verification
```
- Transient markers are written **only when restore is ON**. With restore OFF the transcript
  is a "real" copy, and clipboard managers should record it.
- Plain "copy" (history button, copy-last) = `setClipboard(text, transient: false)`.

### 3.3 Clipboard snapshot and restore
- Snapshot: `pasteboard.pasteboardItems.map { item in item.types.compactMap { (type, item.data(forType:)) } }`.
  This keeps multi-item and multi-type content (rich text, images, file URLs).
- Restore: `clearContents()` + `writeObjects([NSPasteboardItem])`, rebuilding one item per
  saved item. Restoring an empty snapshot just clears the board.
- **Ownership check** (fixes a race from 7feef2b): skip the restore if the user copied
  something new during the delay. Old code compares `.string` and the session-UUID type.
  Simpler equivalent for the rewrite: store `pasteboard.changeCount` right after the write
  and restore only if it is unchanged.
- Minimum delay 0.25 s. Anything shorter can restore before the target app has read the
  pasteboard (slow Electron apps). The default of 2 s is conservative.
- Caveat: `data(forType:)` on lazily promised types forces the source app to render them
  (can be slow for large images or file promises). Acceptable, but do the snapshot before
  anything time-critical.

### 3.4 Keyboard layouts (the non-QWERTY V problem)
- 0x09 is the physical key that is V on ANSI QWERTY. Apps match Cmd shortcuts by the
  **character** the current layout produces. On pure Dvorak or Colemak, 0x09 gives Cmd+K or
  similar, so the paste fails.
- History: cbf7f60 temporarily switched the input source to ABC/US via
  `TISSelectInputSource` around the paste. It was **removed** in 063e8ac (visible layout
  flicker, races). Current workaround: the user picks the "AppleScript" method.
  - AppleScript: `tell application "System Events" to keystroke "v" using command down`
    (character-based, so it works on Dvorak). But for layouts whose localized name ends
    with `"⌘"` ("Dvorak - QWERTY ⌘"), the layout switches to QWERTY while Cmd is held, so
    it uses `key code 9 using command down` instead (dededd4). Detection:
    `TISCopyCurrentKeyboardInputSource()` + `kTISPropertyLocalizedName`, then
    `.hasSuffix("⌘")`.
  - AppleScript needs the `com.apple.security.automation.apple-events` entitlement,
    `NSAppleEventsUsageDescription`, and a one-time "control System Events" TCC prompt.
    Scripts are compiled once and cached. Must run on the main thread.
- **Recommended for the rewrite (no AppleScript):** resolve the key code for "v" in the
  current layout with the Command modifier held, then fall back to 0x09:
  `TISCopyCurrentKeyboardLayoutInputSource()` (use *Layout*, not `...KeyboardInputSource`:
  it also works under IMEs), read `kTISPropertyUnicodeKeyLayoutData`, loop key codes 0...127
  with `UCKeyTranslate(..., kUCKeyActionDown, modifierKeyState: UInt32((cmdKey >> 8) & 0xFF), LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit, ...)`
  and pick the one that yields "v". Passing the cmd modifier state makes the "QWERTY ⌘"
  layouts resolve correctly. Cache the result per input source and invalidate it on
  `kTISNotifySelectedKeyboardInputSourceChanged` (DistributedNotificationCenter).
  Verify on a Dvorak layout. Polish Pro resolves to 0x09 anyway.
- `TISCopy*` returns a +1 object, so use `takeRetainedValue()` (14f7aea fixed a leak). It
  can return nil during fast user switching, so guard it (096df9a). Call it on the main thread.

### 3.5 Auto-send
```
source = CGEventSource(stateID: .privateState)
enterDown/Up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true/false)
.shiftEnter → flags = .maskShift ; .commandEnter → flags = .maskCommand
post both to .cghidEventTap (no gap), requires AXIsProcessTrusted()
```
Fired 500 ms after the Cmd+V task completes, so the target app has finished inserting.

### 3.6 Focus and window config (why the paste lands in the right app)
- The recorder is an `NSPanel` with `styleMask: [.nonactivatingPanel, .fullSizeContentView]`,
  `isFloatingPanel = true`, `level = .floating`, `hidesOnDeactivate = false`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, shown with
  `orderFrontRegardless()` (never `makeKeyAndOrderFront`, never `NSApp.activate`). So our
  app never becomes frontmost, and Cmd+V goes to the app the user was typing in.
- The panel is hidden (`orderOut`) *before* the paste. In the old code
  `canBecomeKey = true` is there only for the assistant follow-up text field (DROP). In the
  rewrite, return `false` so the panel can never steal key focus.
- "Paste last transcription" waits 0.15 s before pasting so the user can release the
  hotkey modifiers.

### 3.7 Accessibility permission
- Check: `AXIsProcessTrusted()` (cheap, callable anytime). Prompt:
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)`.
  Then open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  and **poll** (there is no callback) until it flips to true.
- Gotcha: TCC ties the grant to the code signature. Every re-signed dev build (a different
  signing identity or ad-hoc signing) makes the old entry stale: `AXIsProcessTrusted()`
  returns false while System Settings still shows the toggle ON. The fix is to remove the
  entry and re-add it (or `tccutil reset Accessibility <bundle-id>`). Use a stable
  Developer ID or Apple Development identity for daily builds.
- The app is **not sandboxed** (`com.apple.security.app-sandbox = false`). CGEvent posting
  to other apps does not work from the sandbox, so keep it unsandboxed.

## 4. Code excerpts worth copying the idea of

Paste session with an ownership-checked restore (CursorPaster.swift):
```swift
@MainActor
private static func performPasteSession(_ text: String) async -> PasteResult {
    let pasteboard = NSPasteboard.general
    let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
    let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
    let sessionID = UUID().uuidString
    guard ClipboardManager.setClipboard(text, transient: shouldRestoreClipboard,
                                        sessionID: shouldRestoreClipboard ? sessionID : nil)
    else { return .commandNotPosted }
    await wait(prePasteDelay)                       // 0.10
    let pasteResult = await postPasteCommand()
    if shouldRestoreClipboard {
        scheduleClipboardRestore(savedContents, expectedText: text, sessionID: sessionID, on: pasteboard)
    }
    return pasteResult
}
// restore: wait max(delay, 0.25); guard pasteboard.string(.string) == expectedText
//   && pasteboard.string(forType: pasteSessionType) == sessionID; clearContents(); writeObjects(items)
```

Cmd+V events:
```swift
guard AXIsProcessTrusted() else { return .commandNotPosted }
let source = CGEventSource(stateID: .privateState)
guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
      let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
      let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
      let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
else { return .commandNotPosted }
cmdDown.flags = .maskCommand; vDown.flags = .maskCommand; vUp.flags = .maskCommand
cmdDown.post(tap: .cghidEventTap); await wait(0.01)
vDown.post(tap: .cghidEventTap);   await wait(0.01)
vUp.post(tap: .cghidEventTap);     await wait(0.01)
cmdUp.post(tap: .cghidEventTap)
```

Delivery ordering (TranscriptionDelivery.swift):
```swift
let pastedText = textToPaste + (appendSpace ? " " : "")
SoundManager.shared.playStopSound()
await actions.dismiss()                               // orderOut recorder panel first
let pasteTask = CursorPaster.startPasteAtCursor(pastedText)
Task { @MainActor in
    _ = await pasteTask.value
    if autoSendKey.isEnabled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        CursorPaster.performAutoSend(autoSendKey)
    }
}
```

## 5. Recommended minimal design for the rewrite

- `@MainActor final class TextOutput` is the single entry point:
  `func deliver(_ text: String) async -> OutputResult` and `func copy(_ text: String)`.
  Everything touching NSPasteboard, CGEvent and TIS stays on the MainActor (CGEvent is not
  Sendable, and TIS/NSPasteboard expect the main thread). No static singletons with
  UserDefaults lookups inside. Pass an `OutputSettings` value in.
- `struct OutputSettings { restoreClipboard: Bool = true; restoreDelay: Duration = .seconds(1.5); trailingSpace: Bool = true; autoSend: AutoSendKey = .none }`.
  Store it via `@AppStorage` keys and read it once per delivery.
- `enum AutoSendKey: String { none, enter, shiftEnter, commandEnter }`: a global setting
  (not per mode).
- `struct PasteboardSnapshot { items: [[(NSPasteboard.PasteboardType, Data)]] }` with
  `capture(from:)` and `restore(to:)`. Take ownership via `changeCount` after the write
  instead of a UUID type (still write `org.nspasteboard.source`, `TransientType` and
  `AutoGeneratedType` when restoring).
- `enum KeySynth` with `pasteShortcut() async -> Bool` (Cmd + resolved V key code,
  `.privateState`, `.cghidEventTap`, 10 ms gaps) and `press(_ key: AutoSendKey)`. Both
  guard `AXIsProcessTrusted()`.
- `enum KeyboardLayout` with `keyCodeForV() -> CGKeyCode` (UCKeyTranslate with Cmd
  modifier state, cached per input source, fallback 0x09). This replaces the AppleScript
  path and the `PasteMethod` setting.
- Flow in `deliver`: trim, then append the trailing space → hide the panel (already
  non-activating) → snapshot if restore → write → sleep 100 ms → Cmd+V → optional auto-send
  after 500 ms → schedule the restore.
- **Failure fallback (new, fixes the old bug):** if AX is not trusted or event creation
  fails, do NOT schedule a restore. Leave the transcript on the clipboard (non-transient)
  and show a small "Copied, press ⌘V" toast plus an "Enable Accessibility" action.
  Optional: if
  `AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)`
  returns no element, still post Cmd+V (Electron and some terminals do not expose focus
  reliably) but skip the restore so the text stays pasteable by hand.
- `AccessibilityPermission` helper with `isTrusted`, `prompt()`, `openSettings()`, and
  a polling `AsyncStream<Bool>` (1 s) for onboarding and the settings badge.
- "Paste last transcription" hotkey calls `deliver(lastText)` after a 150 ms delay.
  "Copy" buttons in history call `copy(text)` (plain, non-transient).
- Unsandboxed app, stable signing identity, no Apple Events entitlement needed once
  AppleScript is dropped (unless another subsystem needs it).
- Settings UI (paste section): two toggles, "Restore clipboard" and "Add space after
  paste", plus one picker, "Auto-send: None / ⏎ / ⇧⏎ / ⌘⏎". Nothing else.

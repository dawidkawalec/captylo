# Accessibility coverage (self-learning spike, CAPTYLO-34)

Which apps let Captylo read back the text field it pasted into. The edit watcher (self-learning stage 3) only learns where this works; elsewhere it stays silent.

How to measure: run `Captylo --ax-probe --show-text` from a build that has the Accessibility grant, focus a text field in the app, paste a sentence, edit one word, and watch whether `length`, `selection` and `tail` follow the edit. End to end: focus the field, run `CAPTYLO_DATA_DIR=<scratch> Captylo --watch-paste "Wrzucam to na supa bejs w piątek."`, fix "supa bejs" to "Supabase", click another app; the second run prints the learned rule.

| App | Bundle id | Role of the field | Readable | Follows edits | Notes |
|---|---|---|---|---|---|
| TextEdit | com.apple.TextEdit | AXTextArea | yes | yes | end-to-end with `--watch-paste` (2026-09-28): 2 identical fixes → rule "supa bejs → Supabase" |
| Safari (textarea) | com.apple.Safari | AXTextArea | yes | yes | learned when the fix arrives like typing (AX edit); a page script changing `value` is not seen by WebKit's AX (test artefact only) |
| Chrome (textarea, contenteditable) | com.google.Chrome | AXTextArea / web area | yes, after `AXEnhancedUserInterface` | yes | ignores `AXManualAccessibility`; needs the enhanced flag set at the start of the take (`EditWatcher.prepare`); learned in both field types |
| Edge (textarea, contenteditable) | com.microsoft.edgemac | as Chrome | yes, after `AXEnhancedUserInterface` | yes | learned in both |
| Arc (textarea, contenteditable) | company.thebrowser.Browser | as Chrome | yes, `AXManualAccessibility` is enough | yes | learned in both; the tree builds asynchronously, so the flag goes out when the take starts, not at paste |
| Spark Desktop | com.readdle.SparkDesktop | AXGroup | yes (empty on first check) | ? | Electron, accepted `AXManualAccessibility` |
| Mail | com.apple.mail | | | | |
| Notatki | com.apple.Notes | | | | |
| Slack | com.tinyspeck.slackmacgap | | | | Electron |
| VS Code | com.microsoft.VSCode | | | | Electron, editor may be canvas-like |
| Word | com.microsoft.Word | | | | |
| Telegram | ru.keepcoder.Telegram | | | | |
| Claude desktop | com.anthropic.claudefordesktop | | | | Electron |
| Terminal / iTerm / Warp / Ghostty | com.apple.Terminal ... | | | | always excluded (`EditWatcher.excludedBundleIDs`): the "field" is the whole scrollback |

Not tested on purpose: Mail, Notes, Slack, Word, Claude and other apps with the owner's real data (a test could leave notes or drafts, or send a message). Check them by hand with `--ax-probe --show-text`.

Findings that shaped `EditWatcher`:

- Every AX call gets a 0.5 s messaging timeout (`AXText.messagingTimeout`). The default is about 6 s, and a closed Safari tab held the main actor that long per call.
- Chrome keeps reporting a closed tab's field as the app's focused element; the field's own `AXFocused` does turn false, so the watch asks the element first. When neither says so, the watch still ends on an app switch, the next take or 90 s idle.
- Browsers were tested with local pages (`textarea` and `contenteditable`) that fix "supa bejs" by themselves a few seconds after the paste, and a helper that closes only the test tab (Cmd+W when the window title matches).


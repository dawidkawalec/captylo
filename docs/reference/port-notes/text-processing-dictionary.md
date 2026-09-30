# Port note: Text processing + Dictionary

Source: `<old repo>/VoiceInk` (VocaType 1, a VoiceInk fork). Read-only analysis, 2026-09-25.

## 0. TL;DR - things that matter most

- **Vocabulary does nothing for this user today.** It only reaches (a) the AI enhancement system prompt, and
  (b) cloud providers that support keyword boosting (Deepgram, AssemblyAI, Soniox, ElevenLabs, Speechmatics).
  It is **not** sent to Parakeet/FluidAudio, local whisper.cpp, **Groq** or **Gemini** (both providers
  receive `customVocabulary` but ignore it). The user runs Parakeet with AI enhancement off, so vocabulary has no effect.
  The UI admits this: "Vocabulary is used only with AI enhancement...".
- **Word replacements are the only dictionary feature that affects Parakeet output.** They are deterministic,
  local and fast. Keep them as the main tool.
- There are **no capitalization or punctuation fixes** in the code. Parakeet v3 outputs punctuated, cased text itself.
  The only text changes are: tag/bracket stripping, filler-word removal, whitespace collapse, paragraph breaks, word
  replacements, and a trailing space added on paste.
- The user's actual config (read from `defaults export pl.kawalec.VocaType`): mode "Dictation", model
  `parakeet-tdt-0.6b-v3`, realtime on, `isTextFormattingEnabled: true`, `isAIEnhancementEnabled: false`, language `auto`.
  `FillerWords` and `AppendTrailingSpace` are unset, so the defaults apply (English filler list, trailing space ON).
- The user's dictionary store is **empty** (0 vocabulary rows, 0 replacement rows in a copy of `dictionary.store`
  checked 2026-09-25), so no dictionary data needs migrating now.
- Two confirmed bugs to avoid (verified with a scratch Swift run, see §3.3): the replacement text is passed as a
  regex *template* (`$5` becomes an empty string, `\` is dropped), and the filler regex eats a sentence-ending period.

## 1. What it does for the user

Essential (KEEP):
1. **Vocabulary**: a list of words/phrases (names, jargon). You can add several at once separated by commas.
   Duplicates are checked case-insensitively. Used only as a hint for models and the LLM, never as a direct text edit.
2. **Word replacements**: rules of the form "one or more triggers (comma-separated) -> replacement text".
   Matching is case-insensitive, respects Unicode word boundaries, and the longest trigger goes first. The replacement
   can be multi-line boilerplate (for example "my email" -> address).
3. **Filler-word removal**: an editable list (default English `uh, um, uhm, umm, uhh, uhhh, hmm, hm, mmm, mm, mh, ehh`).
   An empty list turns removal off. There is no separate toggle.
4. **Output filter**: strips `<TAG>...</TAG>` blocks, and anything inside `[...]`, `(...)`, `{...}` (model hallucinations
   such as `[music]` or `(laughs)`).
5. **Paragraph formatting** (`isTextFormattingEnabled`, default true): splits long text into paragraphs
   (`\n\n`) with NaturalLanguage sentence tokenization. It does not rewrite words.
6. **Trailing space on paste** (`AppendTrailingSpace`, default true). This lives in the delivery step but is part of the text shape.
7. **Dictionary export/import**: in the old app, only as part of the full settings backup JSON. Merge on import, never overwrite.

Bloat (DROP):
- iCloud/CloudKit sync of the dictionary (separate `dictionary.store` with `.private("iCloud.com.prakashjoshipax.VoiceInk")`),
  and the "remove exact duplicates on launch/import" cleanup that exists only because of CloudKit duplicates.
- `WordReplacement.isEnabled`: the pipeline filters on it, but no UI ever sets it, so it is always true.
- 4 sort modes for the replacement table (persisted in `wordReplacementSortMode`), the edit sheet with its info popover,
  and the section switcher. Replace them with one simple list per section.
- `WhisperPrompt` (per-language greeting "initial_prompt" for local whisper.cpp, custom per-language prompts,
  `promptDidChange` notifications). This is a style prompt, not vocabulary, and it is only for local Whisper.
- Per-provider vocabulary plumbing for 8 cloud/streaming providers (Deepgram `keyterm`, AssemblyAI `keyterms_prompt`,
  Soniox `context.terms`, ElevenLabs `keyterms`, Speechmatics `additional_vocab`). Drop it along with those providers.
- Per-mode `isTextFormattingEnabled` (Modes system). Use one global toggle instead.
- Trigger-word mode selection (`triggerWordModeSelection`) in the pipeline.
- Full settings backup with the category-picker NSAlert (`BackupOptions`) and the version-mismatch alert.
- Quick-add floating panel plus its global shortcut (`DictionaryQuickAddPanel.swift`). This is optional: add it later if
  wanted, and see §3.6 for the panel config.

## 2. Key files and control flow

| File | Role |
|---|---|
| `Models/VocabularyWord.swift` | `@Model { word: String, dateAdded: Date }` |
| `Models/WordReplacement.swift` | `@Model { id: UUID, originalText: String (comma list), replacementText, dateAdded, isEnabled }` |
| `Transcription/Processing/TranscriptionOutputFilter.swift` | tag/bracket strip + filler removal + whitespace collapse |
| `Transcription/Processing/FillerWordManager.swift` | filler list in `UserDefaults["FillerWords"]` |
| `Transcription/Processing/ParagraphFormatter.swift` | paragraph splitting (NaturalLanguage) |
| `Transcription/Processing/WordReplacementService.swift` | replacement algorithm |
| `Services/DictionaryService.swift` | add/validate/dedupe helpers |
| `Services/CustomVocabularyService.swift` | builds `"Important Vocabulary: a, b, c"` for the LLM |
| `Services/AIEnhancement/AIEnhancementService.swift` (~l.153) | puts vocabulary into the system prompt |
| `Transcription/Cloud/CloudTranscriptionService.swift` | `getCustomDictionaryTerms()` passed to providers |
| `Transcription/Engine/TranscriptionPipeline.swift` | ordering of all steps |
| `Transcription/Engine/TranscriptionDelivery.swift` (l.159) | `AppendTrailingSpace` |
| `Services/BackupTypes.swift`, `BackupImporter.swift`, `ImportExportService.swift` | export/import |
| `VoiceInk.swift` (l.213-260) | SwiftData: 3 stores, dictionary store with CloudKit |
| `Views/Dictionary/*`, `Views/Components/FillerWordsSettingsView.swift` | UI (filler list lives in the AI Models panel) |

Pipeline order (`TranscriptionPipeline.run`, the same in `AudioFileTranscriptionManager`/`AudioFileTranscriptionService`
for file transcription):

```
raw = session.transcribe(audioURL) | serviceRegistry.transcribe(...)
text = TranscriptionOutputFilter.filter(raw)     // tags, brackets, fillers, \s{2,}->" ", trim
text = text.trimmed
text = triggerWordModeSelection(text) ?? text    // DROP
if isTextFormattingEnabled { text = ParagraphFormatter.format(text) }
text = WordReplacementService.applyReplacements(text)   // AFTER formatting
transcription.text = text                        // this is what history stores as "original"
if AI enhancement on -> enhancedText (LLM gets replaced text; vocab in system prompt)
deliver: paste (enhanced ?? text) + (AppendTrailingSpace ? " " : "")
```

Notes on ordering:
- The whitespace collapse `\s{2,}` also turns newlines from the engine into one space. Paragraphs are rebuilt later
  by the formatter, so paragraph breaks survive only because formatting runs after the filter. Keep this order.
- Replacements run after formatting, so a multi-line replacement is not flattened. Keep this order too.
- The realtime/live preview (`partialTranscript`) shows RAW partials with no filtering. Only the final text is processed.

## 3. Exact details that are easy to get wrong

### 3.1 Replacement algorithm (verbatim core, `WordReplacementService.swift`)

```swift
let sortedReplacements = replacements.sorted { $0.originalText.count > $1.originalText.count }
for replacement in sortedReplacements {
    let variants = replacement.originalText
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
    for original in variants {
        if usesWordBoundaries(for: original) {
            // Lookarounds instead of \b so punctuation acts as a word boundary.
            // Word chars are Unicode letters/marks/digits (not just ASCII) so triggers
            // can't match inside words like "vergrößern"; non-spaced scripts are exempt
            // so Latin triggers flush against CJK/Thai still match.
            let escaped = NSRegularExpression.escapedPattern(for: original)
            // scx (Script_Extensions) so shared marks like U+30FC stay exempt too.
            let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
            let pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                modifiedText = regex.stringByReplacingMatches(
                    in: modifiedText, options: [], range: NSRange(modifiedText.startIndex..., in: modifiedText),
                    withTemplate: replacementText)            // BUG: must be escapedTemplate(for:)
            }
        } else {
            // Fallback substring replace for non-spaced scripts
            modifiedText = modifiedText.replacingOccurrences(of: original, with: replacementText, options: .caseInsensitive)
        }
    }
}
```
`usesWordBoundaries` returns false if any scalar is in Hiragana 3040-309F, Katakana 30A0-30FF,
CJK 4E00-9FFF, Hangul AC00-D7AF, or Thai 0E00-0E7F.

Semantics to reproduce:
- Case-insensitive match. The replacement is inserted **verbatim**, with no case preservation.
- A boundary is anything that is not a Unicode letter, mark or digit. Punctuation, spaces and string edges all count.
  `żółw` does NOT match inside `żółwik` (verified). Multi-word triggers work (`voice ink` matches `voice INK!`).
- Rules are applied **sequentially**, so the output of one rule can be matched again by a later rule (chaining).
- The sort is by the length of the **whole comma group string**, not per variant, which is a quirk. In the rewrite,
  flatten all (trigger, replacement) pairs and sort globally by trigger length, longest first.
- Rules come from SwiftData with `#Predicate { $0.isEnabled }`. Regexes are recompiled on every dictation
  (cheap, but in the rewrite precompile them when the dictionary changes).
- Use **NSRegularExpression (ICU)**, not Swift `Regex`. The pattern relies on ICU class subtraction `[[..]-[..]]` and
  `\p{scx=...}`.

### 3.2 Output filter (verbatim, `TranscriptionOutputFilter.swift`)

```swift
private static let hallucinationPatterns = [#"\[.*?\]"#, #"\(.*?\)"#, #"\{.*?\}"#]
static func filter(_ text: String) -> String {
    var filteredText = text
    // Remove <TAG>...</TAG> blocks
    let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
    if let regex = try? NSRegularExpression(pattern: tagBlockPattern) { /* replace with "" */ }
    for pattern in hallucinationPatterns { /* NSRegularExpression(pattern:) replace with "" */ }
    // Remove configured filler words. An empty list is naturally a no-op.
    for fillerWord in FillerWordManager.shared.fillerWords {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) { /* replace "" */ }
    }
    filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    return filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
}
```
- Bracket patterns are not DOTALL, so they do not cross newlines. They also delete legitimate dictated parentheses.
  That is rare with Parakeet but a real risk with Gemini/LLM output. Keep the behavior, but consider limiting it to
  `[...]`/`{...}` plus a known list like `(laughs)`/`(music)`.
- Filler words are managed by `addWord`, which lowercases, trims and dedupes case-insensitively. They are stored as
  `[String]` in `UserDefaults["FillerWords"]`. If the key is absent, the defaults apply.

### 3.3 Verified edge cases (scratch `swift` run of the exact old regexes)

| Input | Old output | Verdict |
|---|---|---|
| replace `cost` -> `$5 fee` in "the price is cost" | `the price is  fee` | BUG: template `$5` = empty group. Fix: `NSRegularExpression.escapedTemplate(for: replacement)` |
| replace `back` -> `C:\dir` | `C:dir` | BUG: same cause |
| `voice ink` -> `VocaType` in "Voice ink rocks, voice INK!" | `VocaType rocks, VocaType!` | OK |
| `żółw` -> `Turtle` in "żółw i żółwik" | `Turtle i żółwik` | OK (Unicode boundary) |
| fillers on "So, um, I think I said um. Then Hmm we go." | `So, I think I said Then we go.` | BUG: `[,.]?` eats the sentence period, and "we" stays lowercase |
| fillers on "Um, hello" | `hello` | OK (but no re-capitalization) |

Rewrite fix for fillers: remove `\b<filler>\b` plus an *optional following comma only*. If the filler was followed
by `.`/`?`/`!`, keep the punctuation and remove the preceding space. Then fix " ," / " ." spacing. Optionally
uppercase the first letter if a sentence-initial filler was removed.

### 3.4 Paragraph formatter (`ParagraphFormatter.swift`)

- Detect the language with `NLLanguageRecognizer.dominantLanguage(for:)` (fallback `.english`), then
  `NLTokenizer(unit: .sentence)` with `setLanguage`. Each sentence is trimmed. Words are counted with
  `NLTokenizer(unit: .word)`, which excludes punctuation.
- Constants: `TARGET_WORD_COUNT = 50`, `MAX_SENTENCES_PER_CHUNK = 4`, `MIN_WORDS_FOR_SIGNIFICANT_SENTENCE = 4`.
- Exact rule: build a tentative chunk by adding sentences until the chunk has >= 50 words. If the chunk has > 4
  "significant" sentences (>= 4 words each), cut it right after the 4th significant one. Emit the chunk joined by `" "`,
  put `"\n\n"` between chunks, and continue from the next unused sentence.
- Effect: short dictations (< 50 words) come out as one line, with sentences re-joined by single spaces
  (existing newlines are flattened). Empty text returns `""`.
- Simplified rule for the rewrite (almost identical output): end the paragraph when words >= 50 OR significant
  sentences == 4. Keep it synchronous and pure. It is fast enough to run inline.

### 3.5 Where vocabulary goes (the only consumers)

AI enhancement system prompt (verbatim from `AIEnhancementService`; `customVocabulary` =
`"Important Vocabulary: " + words.sorted(by word asc).joined(", ")`):
```swift
"""
# Custom Vocabulary
Use these custom vocabulary words, proper nouns, acronyms, product names, and technical terms as the spelling authority. When the text clearly refers to one of these entries, replace similar-sounding or phonetically close transcription mistakes with the exact spelling shown below. Do not force a replacement when the text clearly means something else:
<CUSTOM_VOCABULARY>
\(customVocabulary)
</CUSTOM_VOCABULARY>
"""
```
The system prompt is `[prompt.finalPromptText, customVocabularySection, contextSection].joined("\n\n")`. The user
message is `"\n<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>"`.

Cloud term list (`CloudTranscriptionService.getCustomDictionaryTerms`): fetch sorted by word, trim, drop empties,
dedupe case-insensitively keeping the first spelling.

Groq today (LLMkit `OpenAITranscriptionClient`): `POST https://api.groq.com/openai/v1/audio/transcriptions`,
multipart `file` (audio/wav), `model=whisper-large-v3-turbo`, optional `language`, optional `prompt` (**never sent**),
`response_format=json`, `temperature=0`, `Authorization: Bearer`, timeout 60 s. Response `{"text": "..."}`.
**Easy win:** pass the vocabulary as `prompt` (for example `"Glossary: A, B, C."`). The Whisper prompt is limited to
about 224 tokens, so truncate the list.

Gemini today (LLMkit `GeminiTranscriptionClient`): `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`,
header `x-goog-api-key`, body `{"contents":[{"parts":[{"text":"Please transcribe this audio file. Provide only the transcribed text."},{"inlineData":{"mimeType":"audio/wav","data":"<base64>"}}]}]}`,
timeout 60 s, result `candidates[0].content.parts[0].text` trimmed. **Easy win:** append
`"Spell these terms exactly as written when they occur: A, B, C."` to the text part.

Parakeet (FluidAudio 0.15.5, checked out in `.local-build/SourcePackages/checkouts/FluidAudio`): the old app does not use
vocabulary. FluidAudio *does* ship CTC keyword boosting (`CustomVocabularyContext`, `CustomVocabularyTerm(text:aliases:)`,
`SlidingWindowAsrManager.configureVocabularyBoosting(vocabulary:ctcModels:)`, docs in
`Documentation/ASR/CustomVocabulary.md`). For 0.6B v3 it needs a separate CTC 110M encoder (~97.5 MB extra,
~130 MB RAM, 26x RTF), and it is English-centric (the docs discuss collisions with common English words), so it is
questionable for Polish. It is only wired into the sliding-window manager. **Recommendation:** skip it in v2.0 and rely on
word replacements for Parakeet. Revisit later behind a flag.

### 3.6 Persistence, validation, import/export

- SwiftData container (`VoiceInk.swift`): 3 `ModelConfiguration`s in one container: `default.store` (Transcription),
  `dictionary.store` (VocabularyWord+WordReplacement, CloudKit unless `LOCAL_BUILD`), `stats.store` (SessionMetric),
  all under `~/Library/Application Support/com.prakashjoshipax.VoiceInk/` (a hard-coded legacy path, shared with the upstream app).
  CloudKit is the reason every property has a default value, there is no `@Attribute(.unique)`, and dedupe is manual.
- Old SQLite tables (for a later migration): `ZVOCABULARYWORD(ZWORD, ZDATEADDED)` and
  `ZWORDREPLACEMENT(ZORIGINALTEXT, ZREPLACEMENTTEXT, ZISENABLED, ZDATEADDED, ZID blob)`. Open the file read-only or on a copy.
- Validation (`DictionaryService`): vocabulary input is split on `,` and trimmed. A single duplicate gives the error
  "'X' is already in the vocabulary". Multiple words are silently deduped. For replacements, triggers are split on `,`,
  and adding fails if any trigger (lowercased) already exists in *any* rule ("'X' already exists in word replacements").
  The replacement must be non-empty. On add it is trimmed. On edit (`EditReplacementSheet`) it is NOT trimmed, which
  is inconsistent (trim in both places, but keep internal newlines).
- Backup JSON (the only export format; `BackupFile`, pretty-printed, file name `VocaType_Settings_Backup.json`):
```json
{ "version": "1.x", "customPrompts": [], "modeConfigs": [],
  "vocabularyWords": [ { "word": "Kawalec" } ],
  "wordReplacements": { "craft web, craftweb": "CraftWeb" },
  "generalSettings": { "isTextFormattingEnabled": true, "...": "..." } }
```
  `wordReplacements` is a dictionary keyed by the raw comma string, so `isEnabled`/`dateAdded` are lost and duplicate
  keys collapse (the last one wins). Import merges: it skips words that already exist (case-insensitive), skips rules
  where any trigger conflicts, and skips empty ones. It never deletes. The v2 importer should accept this shape so
  data can be migrated from a v1 backup.
- Quick-add panel (only if kept): `NSPanel` subclass, `styleMask [.nonactivatingPanel, .fullSizeContentView]`,
  `isFloatingPanel = true`, `level = .floating`, `hidesOnDeactivate = false`,
  `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]`, `canBecomeKey = true`, `canBecomeMain = false`,
  `isMovableByWindowBackground`, width 500, height 130 (vocabulary) or 164 (replacement), centered with +60 pt y.
  Esc (`keyCode == 53`) and `resignKey` hide it. It saves `NSWorkspace.shared.frontmostApplication` before showing
  and calls `activate(options: .activateIgnoringOtherApps)` on hide.

## 4. Threading

Everything runs on `@MainActor` (pipeline, services use `ModelContext` from the main container). The text steps are
pure string functions and take milliseconds. In the rewrite, make the processor a `Sendable` value type holding the
precompiled regexes (NSRegularExpression is immutable and documented as thread-safe; if Swift 6 strict checking
complains, wrap it in a small `@unchecked Sendable` struct). The store stays `@MainActor`, and you pass the
processor snapshot into the pipeline.

## 5. Recommended minimal design for VocaType 2

1. `struct ReplacementRule: Codable, Identifiable, Hashable { var id: UUID; var triggers: [String]; var replacement: String }`.
   Store triggers as an array. The UI still accepts comma input, and the importer splits `"a, b"`.
2. `struct DictionaryData: Codable { var version = 1; var vocabulary: [String]; var replacements: [ReplacementRule]; var fillerWords: [String] }`.
   Persist it to `~/Library/Application Support/<v2 bundle id>/dictionary.json` with an atomic write. No SwiftData, no
   CloudKit. Export = save a copy, import = merge.
3. `@MainActor @Observable final class DictionaryStore`: load/save, `addVocabulary(_ input: String) -> String?`
   (comma split, case-insensitive dedupe, error message), `addRule`/`updateRule` (trigger conflict check across rules,
   trim both fields), `remove`, `importJSON(url)` (accepts the v2 file AND the v1 `BackupFile` keys `vocabularyWords`/`wordReplacements`),
   `exportJSON(url)`. On every change it rebuilds `processor`.
4. `struct TextProcessor: Sendable`, built from `DictionaryData` plus settings: precompiled filler regexes, a flattened
   `[(NSRegularExpression?, trigger, escapedTemplate)]` sorted by trigger length descending, and `paragraphs: Bool`.
5. `func process(_ raw: String) -> String`, in this order: strip tags/brackets, remove fillers (fixed regex, keep sentence
   punctuation), collapse whitespace, trim, paragraphs (if on), replacements (`escapedTemplate`!). A pure function
   covered by unit tests (the table in §3.3 plus Polish diacritics, multi-word, multi-line replacement, CJK fallback).
6. `enum VocabularyHints`: `llmSection(words)` (the §3.5 text), `whisperPrompt(words, maxChars: ~600)` for Groq,
   `geminiInstruction(words)`. Cloud and AI clients call these. Parakeet ignores vocabulary.
7. The paragraph formatter is a small pure function (simplified rule in §3.4). Settings expose one toggle,
   "Paragraph breaks", default ON (matches the user's current config).
8. `AppendTrailingSpace` belongs to the paste/delivery module, but keep it default ON so output does not change.
9. The live/realtime preview shows raw partials. Only run `process` on the final text. History stores the processed text.
10. Dictionary UI: one screen with two short lists (Vocabulary chips + Replacements rows "triggers -> replacement"),
    a collapsible "Filler words" chips row, and Import/Export buttons. No sort modes, no edit sheet (inline edit), and
    a UI caption that says honestly that vocabulary helps cloud/AI models while replacements fix Parakeet.

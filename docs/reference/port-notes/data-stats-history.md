# Port note: Data model + Dashboard stats + History

## 0. Read this first (critical findings)

Two code lines exist in the old repo (VocaType 1). They do not match each other:

| | Installed app the user runs | Working tree (`VoiceInk/`, local `main`) |
|---|---|---|
| Source | `git show origin/main:VocaType/...` (folder `VocaType/`) | upstream VoiceInk v2.11 + partial rebrand |
| Binary | `/Applications/VocaType.app`, v1.64 (165), bundle id `com.dawidkawalec.vocatype` | not installed |
| Store dir | `~/Library/Application Support/com.dawidkawalec.VocaType/` | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/` |
| Stores | `default.store` (~23 MB + 2.2 MB WAL, live) and `dictionary.store`. **No `stats.store`** | `default.store`, `dictionary.store`, `stats.store` |
| Recordings | `~/Library/Application Support/com.prakashjoshipax.VocaType/Recordings/` (**a different folder from the store**) | `.../com.prakashjoshipax.VoiceInk/Recordings/`, but retranscribe/cleanup use `pl.kawalec.VocaType/Recordings` (half-done rebrand bug) |
| Dashboard | computed live from all `Transcription` rows (section 5.1) | computed from `SessionMetric` rows (section 5.2) |

- **Import source = the 1.64 schema** (section 3.1, "1.64" column). The v2.11 code is useful only as a reference for richer dashboard formulas.
- Live recordings: **10,341 WAV files, 8.6 GB** (10,288 `<UUID>.wav`, 48 `transcribed_<UUID>.wav`, 5 `retranscribed_<UUID>.wav`). So audio cleanup is off in practice. Do not copy these files blindly on import.
- The live SQLite schema was not inspected while writing this note. Section 3.5 describes the expected Core Data layout. Verify it once with `sqlite3 -readonly <COPY of store> '.schema'` before relying on it.
- Streaks: **no streak metric exists in either version.** If we want one, it is a new feature (definition proposed in section 5.3).

## 1. What the subsystem does (keep vs drop)

KEEP (essential):
- Persist every dictation: raw text, optional enhanced text, timestamp, audio duration, audio file, model name, processing times, status.
- Dictionary data: vocabulary words (hints for the model) + word replacements (post-processing).
- Dashboard: time saved, sessions, total words, WPM, keystrokes saved, a daily trend chart (words/minutes/sessions, 7/14/30 days, daily or cumulative).
- History: search (text + enhanced text), paged list newest-first, expand a row, copy original/enhanced, play audio (with 1x/1.5x/2x), show in Finder, retranscribe the audio, delete one, multi-select + bulk delete, CSV export of the selection.
- Retention settings: auto-delete transcripts after N (off by default) and auto-delete audio after N days (off by default).

DROP (bloat):
- `SessionMetric` separate store + one-time `HasCompletedStatsMigration` / `HasCompletedStatsTokenBackfillV3` jobs + JSON snapshot cache (`dashboard-stats-snapshot.json`) + debounce/"stale" machinery. Replace with a small, append-only stats table written in the same save as the dictation (section 9).
- Estimated token stats, model usage/performance panels, peak hours card, book-equivalence benchmark ("War and Peace"), "Insights locked until 30 min", GitHub star prompt, license/trial banners, dashboard display name editor, "Copy System Info".
- History "Analyze" (`PerformanceAnalysisView`, `HistoryAnalysisPanelView`), left/right resizable sidebars, the separate 1150x700 History `NSWindow`, re-enhance with a prompt picker, mode (Power Mode) columns.
- `aiRequestSystemMessage` / `aiRequestUserMessage` persisted on every row (large, only used for token estimates and debugging).
- CloudKit sync of the dictionary store (`iCloud.com.prakashjoshipax.VoiceInk`), `powerModeName/Emoji` / `modeName/Emoji`.

## 2. Key files

1.64 (read with `git show origin/main:<path>`):
- `VocaType/Models/Transcription.swift`, `VocabularyWord.swift`, `WordReplacement.swift`
- `VocaType/VocaType.swift` (ModelContainer, lines ~35-190)
- `VocaType/Views/MetricsView.swift`, `VocaType/Views/Metrics/MetricsContent.swift` (formulas), `DashboardTrendsCard.swift` (chart)
- `VocaType/Views/TranscriptionHistoryView.swift`, `TranscriptionCard.swift`, `AudioPlayerView.swift`
- `VocaType/Services/VoiceInkCSVExportService.swift`, `TranscriptionAutoCleanupService.swift`, `VocaType/Views/Settings/AudioCleanupManager.swift`, `AudioCleanupSettingsView.swift`
- `VocaType/Whisper/WhisperState.swift` (Recordings dir, row creation, lines ~115-420)

v2.11 (working tree, `<old repo>/VoiceInk/`):
- `Models/{Transcription,SessionMetric,VocabularyWord,WordReplacement}.swift`, `VoiceInk.swift` (3-store container)
- `Services/SessionMetricRecorder.swift`, `Services/SessionMetricMigrationService.swift`, `Services/WordCounter.swift`, `Services/EstimatedTokenCounter.swift`
- `Views/Dashboard/DashboardStatsLoader.swift` (all aggregation), `DashboardStatsModels.swift` (periods, time-saved, benchmark), `DashboardContent.swift`
- `Transcription/Engine/TranscriptionPipeline.swift` (~L150-265: status + metric write, paste happens BEFORE save)
- `Views/History/*`, `Views/AudioPlayerView.swift`, `Services/AudioFileTranscriptionService.swift` (retranscribe), `AppDefaults.swift` (`CleanupSettingsKeys`)

## 3. Data model

### 3.1 `Transcription` (store `default.store`, config name `"default"`)

| Field | Type | 1.64 | v2.11 | Meaning / gotcha |
|---|---|---|---|---|
| id | UUID | yes (no default) | `= UUID()` | Not `.unique`. Stable key for import. |
| text | String | yes | yes | Raw transcript after filters + word replacements. **On failure it holds `"Transcription Failed: <error>"`**. v2.11 canceled rows hold `"The transcription was canceled."` |
| enhancedText | String? | yes | yes | AI output. **On enhancement error it holds `"Enhancement failed: <error>"`** (1.64) while `enhancementDuration` stays nil. |
| timestamp | Date | yes | yes | Set in `init` = creation time (recording stop), not update time. |
| duration | TimeInterval | yes | yes | Audio length in seconds, from `AVURLAsset(url).load(.duration)`. |
| audioFileURL | String? | yes | yes | `URL.absoluteString`, e.g. `file:///Users/<you>/Library/Application%20Support/com.prakashjoshipax.VocaType/Recordings/<UUID>.wav` (percent-encoded). Parse with `URL(string:)`, use `.path`. |
| transcriptionModelName | String? | yes | yes | `model.displayName` (e.g. "Parakeet V3"). |
| aiEnhancementModelName | String? | yes | yes | Enhancement model id. |
| promptName | String? | yes | yes | Enhancement prompt title. |
| transcriptionDuration | TimeInterval? | yes | yes | Wall-clock processing time of the STT call. |
| enhancementDuration | TimeInterval? | yes | yes | Wall-clock time of the LLM call; non-nil only on success. |
| aiRequestSystemMessage / aiRequestUserMessage | String? | yes | yes | Full prompt sent to LLM. Drop. |
| powerModeName / powerModeEmoji | String? | yes (these names) | renamed `modeName/modeEmoji` with `@Attribute(originalName: "powerModeName")` | Drop. |
| transcriptionStatus | String? | `pending/completed/failed` | + `canceled` | See status bug below. |

**Status bug (affects import):** rows created by "Transcribe audio file" (`transcribed_*.wav`) and "Retranscribe" (`retranscribed_*.wav`) are built with `Transcription(...)` without a status argument, so they keep the init default `.pending` forever, in both 1.64 and v2.11. Also any row whose app crashed mid-transcription stays `pending` with `text == ""`. Retranscribe INSERTS A NEW ROW (copying the wav to `retranscribed_<UUID>.wav`); it never updates the original row.

### 3.2 Dictionary models (store `dictionary.store`, config name `"dictionary"`)

- `VocabularyWord { word: String; dateAdded: Date }`. 1.64 has `@Attribute(.unique) var word`; v2.11 removed `.unique` (CloudKit forbids it) and instead dedupes on every launch (`DictionaryService.removeExactDuplicateContent`: keep oldest by `dateAdded`, delete exact duplicates of `word`, and of `[originalText, replacementText]` pairs).
- `WordReplacement { id: UUID; originalText: String; replacementText: String; dateAdded: Date; isEnabled: Bool }`. `originalText` is a **comma-separated list of variants**; each variant is trimmed and replaced case-insensitively with a `\b...\b` regex (`NSRegularExpression.escapedPattern`), plain `replacingOccurrences(.caseInsensitive)` fallback.

### 3.3 `SessionMetric` (v2.11 only, store `stats.store`, config `"stats"`)

`id, transcriptionId (UUID), timestamp, source ("recorder"), wordCount, audioDuration, transcriptionModelName?, transcriptionDuration?, speedFactor? (= audio/processing), modeName? (originalName powerModeName), aiEnhancementModelName?, enhancementDuration?, enhancementEstimatedTokenCount?`.
Design intent worth keeping: **stats live separately from history, so deleting history (manually or by retention) does not reduce totals.** Written only for `completed` rows, deduped by `transcriptionId` via `fetchCount` before insert.

### 3.4 Container setup, locations, migrations

- One `ModelContainer(for: Schema([all models]), configurations: transcriptConfig, dictionaryConfig[, statsConfig])`. Each `ModelConfiguration(name, schema: Schema([subset]), url: explicitURL, cloudKitDatabase: .none)`. Base dir = `FileManager.urls(.applicationSupportDirectory)[0]/<folder>`, created with `createDirectory(withIntermediateDirectories: true)`. App is NOT sandboxed (`com.apple.security.app-sandbox = false`), so paths are real `~/Library/Application Support/...`.
- Fallback: if persistent init throws, build the same configs with `isStoredInMemoryOnly: true` and show an NSAlert "Storage Warning". Keep this idea (never crash on a broken store).
- Migrations: **none explicit** (no `VersionedSchema` / `SchemaMigrationPlan` anywhere). Relies on SwiftData lightweight migration: v2.11 added default values to every property + `canceled` status + `@Attribute(originalName:)` renames. Lesson: give every property a default from day one and only add optional fields; then lightweight migration is enough.
- v2.11 comment: "Keep existing model order stable; append new models after synced entities." (Schema order matters with CloudKit; irrelevant once CloudKit is dropped.)

### 3.5 Expected raw SQLite layout (Core Data under SwiftData) for a SwiftData-free importer

UNVERIFIED, standard Core Data naming. Check with `.schema` on a copy.
- Table `ZTRANSCRIPTION`: `Z_PK, Z_ENT, Z_OPT, ZID (BLOB, 16 raw UUID bytes), ZTEXT, ZENHANCEDTEXT, ZTIMESTAMP (REAL), ZDURATION (FLOAT), ZAUDIOFILEURL, ZTRANSCRIPTIONMODELNAME, ZAIENHANCEMENTMODELNAME, ZPROMPTNAME, ZTRANSCRIPTIONDURATION, ZENHANCEMENTDURATION, ZAIREQUESTSYSTEMMESSAGE, ZAIREQUESTUSERMESSAGE, ZPOWERMODENAME, ZPOWERMODEEMOJI, ZTRANSCRIPTIONSTATUS`.
- `ZVOCABULARYWORD (ZWORD, ZDATEADDED)`, `ZWORDREPLACEMENT (ZID, ZORIGINALTEXT, ZREPLACEMENTTEXT, ZDATEADDED, ZISENABLED INTEGER 0/1)`.
- Dates are seconds since 2001-01-01 UTC: `Date(timeIntervalSinceReferenceDate: z)` (Unix = z + 978307200).
- Store is in WAL mode (the WAL holds recent rows). Always copy `default.store`, `default.store-wal`, `default.store-shm` together while the old app is NOT running, then open the copy.

## 4. Write path (when rows change)

1.64 `WhisperState.toggleRecord` -> on stop: `Transcription(text: "", duration: assetDuration, audioFileURL: file.absoluteString, status: .pending)`, `insert`, `save`, post `.transcriptionCreated`, then `transcribeAudio(on:)` fills `text/duration/transcriptionModelName/transcriptionDuration`, optional enhancement fields, sets `completed` or (on throw) `text = "Transcription Failed: ..."` + `failed`, `save()`, then pastes.
v2.11 improvement: **paste first, then save** (`delivery.deliver(...)` then `saveTranscriptionAndPostCompletion()`), and the SessionMetric insert happens in that same save. Keep "paste first" for latency.
Recording file name: `"\(UUID().uuidString).wav"` in the Recordings dir, format **16 kHz, mono, PCM Int16 WAV** (1.64 `AudioEngineRecorder`: `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1)`; v2.11 `CoreAudioRecorder` same via `kAudioFormatLinearPCM | SignedInteger | Packed`). Average live file is ~830 KB (~26 s).

## 5. Dashboard metrics (exact formulas)

### 5.1 1.64 dashboard (what the user sees today). Source: `MetricsContent.swift`, `DashboardTrendsCard.swift`

Input: `@Query(sort: \Transcription.timestamp)` = **every row, including failed/pending/empty**, loaded on the main thread.

| Metric | Formula |
|---|---|
| Sessions | `transcriptions.count` |
| Words | `sum(t.text.split(separator: " ").count)` (raw `text` only, never `enhancedText`; splits on spaces only, so `"a\n\nb"` counts as 1; failed rows count their error string) |
| Recorded time | `sum(t.duration)` |
| WPM ("voice pace") | `words / (recordedTime / 60)`, shown `"%.1f"`, "-" if recordedTime == 0 |
| Keystrokes saved | `Int(words * 5.0)` |
| Time saved (hero) | `max(words / 35 * 60 - recordedTime, 0)` seconds (**35 WPM** typing assumption). Formatted with `DateComponentsFormatter`, `unitsStyle .full`, `maximumUnitCount 2`, units `[.hour,.minute]` if >= 3600 s else `[.minute,.second]`; fallback "Time savings coming soon" when 0 |
| Hero subtitle | `"Dictated \(words) words across \(n) session(s)."` |

Trends card: segmented pickers `Daily|Total`, `Words|Minutes|Sessions`, `7d|14d|30d` (default Daily/Words/14d). Days = `startOfDay(today) - (N-1) ... today`, grouped by `Calendar.current.startOfDay(for: timestamp)`; per day: words (same split rule), sessions = count, minutes = `sum(duration)/60`. Daily = `BarMark` per day (corner 3, accent 0.82); Total = running cumulative sum as `AreaMark` (0.14) + `LineMark` (2 pt, catmullRom). Height 110. X stride 1/2/5 days for 7/14/30, label format `"d MMM"`. Y: 3 ticks, abbreviated (`1.2k`, `3.4M`). Summary pill: Daily = `"avg X/day · best Y"`; Total = `"total X · avg Y/day"` (avg over all N days incl. zero days; minutes `"%.1f"` if < 10).

### 5.2 v2.11 formulas (reference, mostly dropped)

- Word count = `NLTokenizer(unit: .word)` token count (ignores punctuation, handles newlines; numbers differ from 1.64's split).
- Text counted = `enhancedText` if `enhancedText != nil && enhancementDuration != nil && !isEmpty`, else `text` (the `enhancementDuration` guard skips "Enhancement failed: ..." strings). Only `completed` rows.
- Time saved = `max(words / 40 * 60 - audioDuration, 0)` (**40 WPM** here vs 35 in 1.64).
- Periods (calendar = current, `firstWeekday = 2`): today `[startOfDay, now]`, last 7 days `[startOfDay - 6d, now]`, previous 7 days `[start7 - 7d, start7)`, last 30 `[startOfDay - 29d, now]`, this year `[start of year, now]`, all time.
- Productivity chart: today = 24 hourly buckets, 7d = daily labeled `"E"`, 30d = daily labeled `"d"`, this year = monthly `"MMM"`, all time = monthly from first metric month.
- Peak hours: per-hour words/sessions; best 2-hour window `h, (h+1)%24` by words, tie-break by sessions; end = `(h+2)%24`.
- Model performance: avg processing time per model; speed factor = `sum(audio) / sum(processing)`. Token estimate = `max(1, (chars + 3) / 4)` over trimmed `system + user + enhancedText` (fallback: `text`).
- Header copy: `recentSevenDayCount >= 5` -> "on a roll this week"; `> 0` -> "building momentum".
- Recent transcripts on dashboard: last 5 where text is non-empty, status not failed/canceled, and not prefixed `"Transcription Failed:"` (case-insensitive, anchored).
- Loader: `Task.detached(priority: .utility)`, fresh `ModelContext(container)`, pages of 5,000 sorted by timestamp, `Task.checkCancellation()` per page.

### 5.3 Streaks (new, if wanted)

Not present anywhere. Suggested definition: set of `startOfDay(createdAt)` for completed sessions; current streak = consecutive days ending today (or yesterday if nothing yet today); longest streak = longest consecutive run.

## 6. History features (1.64 = target behavior)

- Paged list, `pageSize = 20`, newest first, cursor = last row's `timestamp`, "Load more" button. `hasMoreContent = page.count == pageSize`. Gotcha: `timestamp < cursor` can skip rows with an identical timestamp; use `(timestamp, id)` or offset paging.
- Search: `text.localizedStandardContains(q) || (enhancedText?.localizedStandardContains(q) ?? false)` inside `#Predicate`; reloads from page 1 on every keystroke. There are **no other filters** (no date/status/model filter) in 1.64.
- Auto-refresh: a `@Query` with `fetchLimit = 1` on newest `timestamp`; when its id changes and the view is visible, reset paging and reload.
- Row: date (`.dateTime.month(.abbreviated).day().year().hour().minute()`), duration badge, tabs Original / Enhanced (default Enhanced when present), copy button for the current tab, context menu "Copy Enhanced" / "Copy Original" / "Delete". Expanded: audio player + metadata (audio duration, model, prompt, transcription time, enhancement time). Timing format: `< 1 s -> "%.0fms"`, `< 60 -> "%.1fs"`, else `"%dm %.0fs"`.
- Audio player: `AVAudioPlayer`, 0.1 s progress timer, waveform of 200 samples, rate cycle 1.0 -> 1.5 -> 2.0 persisted in `audioPlaybackRate`, Show in Finder via `NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: dir)`, Retranscribe (current model, creates a new row, see 3.1).
- Delete (single and bulk): remove audio file (`URL(string: audioFileURL)`), `modelContext.delete`, `save`, reload. Bulk has a confirmation alert "This action cannot be undone...". Select All in 1.64 fetches ALL matching rows (not just the displayed page).
- CSV export (selected rows), `NSSavePanel`, default name `VocaType-transcription.csv`, UTF-8, header: `Original Transcript,Enhanced Transcript,Enhancement Model,Prompt Name,Transcription Model,Power Mode,Enhancement Time,Transcription Time,Timestamp,Duration`; timestamp = `ISO8601Format()`. Escaping bug: quotes are doubled but the field is only wrapped when it contains `,` or `\n`, so a field with `"` alone (or `\r`) produces invalid CSV. Fix: always wrap when the field contains `"`, `,`, `\n` or `\r`.

## 7. Retention / cleanup settings (UserDefaults keys, both versions)

- `IsTranscriptionCleanupEnabled` (Bool, default false) + `TranscriptionRetentionMinutes` (Int, default 1440; options 0 = Immediately, 60, 1440, 4320, 10080). Implemented by observing `.transcriptionCompleted`: minutes == 0 deletes that row + audio right away; otherwise sweeps `timestamp < now - minutes*60` in a background `ModelContext`. v2.11 also deletes orphan WAVs with no row on launch.
- `IsAudioCleanupEnabled` (Bool, default false) + `AudioRetentionPeriod` (days, default 7; options 1/3/7/14/30). Daily `Timer` (86400 s) deletes WAVs of rows with `timestamp < now - days` and sets `audioFileURL = nil` (text kept). Settings shows a preview "delete N files, frees X". Audio cleanup is skipped when transcript cleanup is on.

## 8. Code worth copying the idea of

1.64 multi-store container (trimmed):
```swift
let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("com.dawidkawalec.VocaType", isDirectory: true)
try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
let transcriptConfig = ModelConfiguration("default", schema: Schema([Transcription.self]),
    url: appSupportURL.appendingPathComponent("default.store"), cloudKitDatabase: .none)
let dictionaryConfig = ModelConfiguration("dictionary", schema: Schema([VocabularyWord.self, WordReplacement.self]),
    url: appSupportURL.appendingPathComponent("dictionary.store"), cloudKitDatabase: .none)
return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig)
```

v2.11 metric write, deduped, same save as the row (`SessionMetricRecorder`):
```swift
guard transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else { return false }
let transcriptionId = transcription.id
let descriptor = FetchDescriptor<SessionMetric>(
    predicate: #Predicate<SessionMetric> { $0.transcriptionId == transcriptionId })
if try modelContext.fetchCount(descriptor) > 0 { return false }
let wordCount = WordCounter.count(in: finalTextForCounting(from: transcription))
let audioDuration = max(transcription.duration, 0)
let transcriptionDuration = transcription.transcriptionDuration.flatMap { $0 > 0 ? $0 : nil }
let speedFactor = transcriptionDuration.flatMap { audioDuration > 0 ? audioDuration / $0 : nil }
modelContext.insert(SessionMetric(transcriptionId: transcription.id, timestamp: timestamp,
    wordCount: wordCount, audioDuration: audioDuration, /* ... */))
```

Word counter:
```swift
let tokenizer = NLTokenizer(unit: .word)
tokenizer.string = text
return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
```

Cursor-paged search predicate (1.64, correct capture of local `let`s is required by `#Predicate`):
```swift
descriptor.predicate = #Predicate<Transcription> { t in
    (t.text.localizedStandardContains(searchText) ||
     (t.enhancedText?.localizedStandardContains(searchText) ?? false)) &&
    t.timestamp < timestamp
}
descriptor.fetchLimit = pageSize
```

## 9. Recommended minimal design for the rewrite

- **One store file, no CloudKit**: `~/Library/Application Support/<new bundle id>/VocaType.store`, audio in `<same dir>/Recordings/`. Every `@Model` property gets a default value, so future changes stay lightweight migrations. Keep the in-memory fallback + alert.
- `@Model Dictation`: `@Attribute(.unique) id: UUID` (= old `Transcription.id` on import, makes import idempotent), `createdAt: Date`, `rawText: String`, `enhancedText: String?` (success only), `status: String` (`completed|failed|canceled`), `errorMessage: String?` (never write errors into `rawText`), `audioDuration: Double`, `audioFileName: String?` (file name only, resolved against Recordings dir, so moving folders never breaks links), `modelName: String?`, `transcriptionTime: Double?`, `enhancementModelName: String?`, `enhancementTime: Double?`, `wordCount: Int` (computed once at save), `source: String` (`dictation|file|import`).
- `@Model UsageStat` (append-only, never deleted by history delete or retention): `dictationId: UUID`, `createdAt`, `wordCount`, `audioDuration`, `transcriptionTime?`, `modelName?`. Inserted in the same `save()` as the `Dictation` when status == completed. Dashboard reads only this table.
- `@Model VocabularyWord { @Attribute(.unique) word, dateAdded }`, `@Model WordReplacement { @Attribute(.unique) id, originalText (comma-separated variants), replacementText, isEnabled, dateAdded }`.
- `StatsService` (actor or `Task.detached` with its own `ModelContext(container)`): fetch all `UsageStat` (10k rows is trivial), compute totals + daily buckets; recompute on a `dictationSaved` notification. No snapshot file, no debounce, no migration flags.
- Dashboard numbers: Sessions = count(completed), Words = sum(wordCount), WPM = words / (sum(audioDuration)/60), Keystrokes = words * 5, Time saved = max(words / 40 * 60 - audioSeconds, 0). Decide 35 vs 40 WPM once (1.64 shows 35), plus the 7/14/30-day Daily/Total trend chart. Optional streak (5.3).
- `HistoryStore`: paged fetch (`fetchLimit 50`, sort by `createdAt` desc, then `id`), search predicate on rawText/enhancedText, delete (row + wav), bulk delete, CSV export (fixed escaping), copy, play (`AVAudioPlayer`), retranscribe that **updates the same row** instead of inserting a duplicate.
- `RetentionService`: two optional rules (transcripts after N minutes, audio after N days), run on launch + after each save; never touches `UsageStat`.
- Recording file naming: `<UUID of the Dictation>.wav`, 16 kHz mono Int16, so row and file share one id.
- **Importer (one-shot, idempotent)**: (1) refuse if `NSRunningApplication.runningApplications(withBundleIdentifier: "com.dawidkawalec.vocatype")` is non-empty; (2) copy `default.store{,-wal,-shm}` + `dictionary.store{,-wal,-shm}` from `~/Library/Application Support/com.dawidkawalec.VocaType/` to a temp dir; (3) read with `SQLite3` `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)` (no need to reproduce the old `@Model` classes, and it avoids entity-name clashes); (4) map: `ZID` blob -> UUID, `ZTIMESTAMP` -> `Date(timeIntervalSinceReferenceDate:)`; status: `completed` stays completed, text prefixed `Transcription Failed:` -> failed (move text to `errorMessage`), `pending` with non-empty text -> completed (fixes the file/retranscribe bug), empty text -> skip; `enhancedText` prefixed `Enhancement failed:` or with nil `ZENHANCEMENTDURATION` -> nil; (5) `audioFileName = URL(string: ZAUDIOFILEURL)?.lastPathComponent`, and look up that name in `com.prakashjoshipax.VocaType/Recordings/` (then `com.prakashjoshipax.VoiceInk/Recordings/`); (6) recompute `wordCount` with the new counter and create one `UsageStat` per completed row; (7) upsert by id and skip existing ids.
- Audio on import: 8.6 GB. Default = do not copy; offer "copy last 30 days" or "move all". Rows without a file simply show no player.
- Dictionary import: dedupe the same way as v2.11 (keep oldest by `dateAdded`), skip empty words.

## 10. Open items to verify

- Run `.schema` + `SELECT ZTRANSCRIPTIONSTATUS, COUNT(*) FROM ZTRANSCRIPTION GROUP BY 1` on a COPY of the live store (needs the user's permission) to confirm section 3.5 and the pending/failed counts.
- Confirm the user's current retention settings in `com.dawidkawalec.vocatype` defaults (`IsAudioCleanupEnabled`, `IsTranscriptionCleanupEnabled`) if we want to carry them over (default: off).
- Note that 1.64's dashboard totals will shift after import, because failed/pending rows get excluded and word counting changes (split vs NLTokenizer). If the user wants the exact same "words" number, use `text.split(separator: " ")` for imported rows only.

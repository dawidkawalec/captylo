# Port note: local transcription engines (Parakeet via FluidAudio, realtime preview)

Old source root: `<old repo>/VoiceInk` (VoiceInk fork, bundle `pl.kawalec.VocaType`, NOT sandboxed).
FluidAudio checkout: `<old repo>/.local-build/SourcePackages/checkouts/FluidAudio`
(pinned to `branch: main`, revision `88d6d816`, = `v0.15.5-28`). **Rewrite: pin a tag (`from: "0.15.5"` or newer), not `main`.**

User's actual config (decoded from `defaults read pl.kawalec.VocaType` key `modeConfigurationsV2`):
`selectedTranscriptionModelName = "parakeet-tdt-0.6b-v3"`, `isRealtimeTranscriptionEnabled = true`,
`selectedLanguage = "auto"`, `outputMode = "paste"`, `isAIEnhancementEnabled = false`, `isTextFormattingEnabled = true`.

## 1. What it does for the user

Keep (essential):
- Download Parakeet TDT 0.6b v3 once (~460 MB on disk), show progress, then "optimizing for your device" (CoreML/ANE compile on first load).
- Offline, on-device transcription of the recorded 16 kHz mono WAV. 25 European languages incl. Polish, punctuation and casing come from the model.
- Realtime **live preview** in the recorder widget while speaking (text updates every ~1 s).
- Final text on stop. For typical short dictations the final text comes from a **full batch pass over the WAV file**, not from the streaming text (see 3.4). That is the fast, accurate path.
- Prewarm the model at app launch and after wake so the first dictation is instant.
- Optional language hint (`pl`) that filters out wrong-script tokens (Cyrillic confusion for Slavic languages).

DROP (bloat):
- whisper.cpp (`Transcription/Whisper/*`, 15+ ggml models, VAD model manager, prompt, warmup coordinator). It needs a hand-built `whisper.xcframework` from `$(HOME)/VoiceInk-Dependencies/whisper.cpp/build-apple/`. Parakeet is faster and more accurate for this user.
- TranscribeCpp / Cohere Transcribe (`Transcription/TranscribeCpp/*`, 1.56 GB model).
- Parakeet V2 (English only), Parakeet Unified (English only, 1.2 GB), Nemotron Latin/Multilingual (true streaming, 620-670 MB, lower accuracy 0.90-0.92). Nemotron multilingual does support `pl-PL`. Keep it only as a "maybe later" true-streaming option.
- Native Apple SpeechAnalyzer (macOS 26 only, batch only, locale asset reservation dance). Optional: keep as a zero-download fallback only if trivial.
- All ~10 cloud streaming providers (another note covers cloud; Gemini batch was only tried in onboarding).
- Per-mode realtime toggles, per-mode model choice, `TranscriptionRealtimeSupport`, `StreamingStopDisposition` plumbing for 12 providers, metrics classes, custom cloud models.
- Separate prewarm `TranscriptionServiceRegistry` (see bug 3.8).

## 2. Key files and control flow

| File | Role |
|---|---|
| `Transcription/FluidAudio/FluidAudioModelManager.swift` (474 l) | download/delete/exists checks, progress UI, cache paths |
| `Transcription/FluidAudio/FluidAudioTranscriptionService.swift` (208 l) | batch transcription, model cache (`AsrModels`), `AsrManager` lifecycle |
| `Transcription/Streaming/FluidAudioStreamingProvider.swift` (271 l) | pseudo-streaming for Parakeet TDT: re-transcribe the unconfirmed tail every 1 s |
| `Transcription/Streaming/WordAgreementEngine.swift` (259 l) | LocalAgreement-style word confirmation (the clever part) |
| `Transcription/Streaming/StreamingTranscriptionService.swift` (446 l) | generic chunk queue, event consumer, commit wait with 10 s timeout |
| `Transcription/Streaming/PCMAudioConverter.swift` | Int16 LE PCM `Data` to `[Float]` |
| `Transcription/Engine/TranscriptionSession.swift` | `StreamingTranscriptionSession`: stream, fall back to batch |
| `Transcription/Engine/VoiceInkEngine.swift` | wires recorder chunks to session, publishes `partialTranscript` |
| `Services/ModelPrewarmService.swift` | transcribes bundled `sound7.wav` 3 s after launch and after `NSWorkspace.didWakeNotification` |
| `CoreAudioRecorder.swift` (~l.453, l.1065) | writes 16 kHz mono Int16 WAV and emits the same PCM bytes as `onAudioChunk` |
| `Models/TranscriptionModelRegistry.swift` | model catalog (Parakeet v3 entry: size "494 MB", `supportsStreaming: true`) |

Control flow (realtime ON, Parakeet v3):
1. Hotkey, then `recorder.startRecording(toOutputFile: <UUID>.wav)`. `recorder.onAudioChunk = RealtimeAudioChunkGate.receive` buffers chunks (max 2048) until the session exists.
2. Engine resolves the model and calls `serviceRegistry.createSession(onPartialTranscript:)`, which gives `StreamingTranscriptionSession`. `prepare()` returns the chunk callback immediately. `startStreaming()` runs in a background Task. Gate flushes buffered chunks into the callback.
3. In parallel, a Task calls `fluidAudioTranscriptionService.loadModel(for:)` to pre-create the **batch** `AsrManager`, so the fallback on stop is hot.
4. `FluidAudioStreamingProvider.connect()` does `getOrLoadModels(.v3)` (shared cached `AsrModels`), then a **new** `AsrManager(config: .default)` + `loadModels(models)`, then starts a 1 s loop.
5. Every 1 s: take audio from `hypothesisStartTime` to the end, append 1 s of zeros, `asrManager.transcribe(samples, decoderState: &fresh, language:)`, merge SentencePiece tokens to timed words, run the agreement engine. Emit `.partial(fullText)` and, when words get confirmed, `.committed(normalized)`. Trim the buffer up to `hypothesisStartTime`.
6. `onPartialTranscript` hops to MainActor, which sets `engine.partialTranscript`, which drives `LiveTranscriptView` (56 pt high, auto-scroll to bottom, top fade mask, animations disabled).
7. Stop: `recorder.stopRecording()` (WAV finalized), then `session.transcribe(audioURL:)`:
   - if `confirmedSegmentCount < 3`, `.useBatchFallback`: tear down streaming, then `FluidAudioTranscriptionService.transcribe(audioURL:)` on the full WAV (**the normal case**);
   - else drain chunks, `commit()`: final pass on the unconfirmed tail. Final = committed segments joined by " " + tail. Waits max 10 s for the commit signal.
   - any streaming error or failed connect also falls back to batch.
8. Pipeline: `TranscriptionOutputFilter.filter` (strip `[..]`, `(..)`, `{..}`, `<TAG>..</TAG>`, filler words, collapse spaces), then trim, paragraph formatting, word replacements, paste.
9. `cleanupResources()` after every dictation: `AsrManager.cleanup()` on managers, **but `cachedModels: AsrModels` stay in memory**, so the next recording only re-creates a cheap `AsrManager`.

## 3. Exact technical details (easy to get wrong)

### 3.1 Paths and files
- Root: `~/Library/Application Support/FluidAudio/Models/` (`MLModelConfigurationUtils.defaultModelsDirectory`). Not sandboxed, so a new unsandboxed app **reuses the already-downloaded model with no re-download**. A sandboxed app would resolve to its container and must re-download.
- v3 folder = `AsrModels.defaultCacheDirectory(for: .v3)` = `.../Models/parakeet-tdt-0.6b-v3` (`Repo.parakeetV3.folderName` = repo name minus `-coreml`). Contents on this Mac: `Preprocessor.mlmodelc`, `Encoder.mlmodelc` (int8), `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, `parakeet_vocab.json`, `parakeet_v3_vocab.json`, `config.json` (`{}`). Total 461 MB.
- `.../Models/parakeet-tdt-0.6b-v3-coreml` (old layout with `JointDecision.mlmodelc`, dated May 26) is a **stale leftover** from an older FluidAudio. It is safe to ignore or delete.
- `modelsExist(at:version:)` checks `requiredModelsV3(precision: .int8)` = {Preprocessor, Encoder, Decoder, JointDecisionv3}.mlmodelc + `parakeet_vocab.json`.
- Downloads come from `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/...` (overridable via `REGISTRY_URL` env). Needs `com.apple.security.network.client`.

### 3.2 FluidAudio public API actually used (signatures from the checkout)
```swift
// Types: AsrModelVersion (.v2/.v3/...), AsrModels (Sendable struct of MLModels), ASRConfig.default
public actor AsrManager {
  public init(config: ASRConfig = .default, models: AsrModels? = nil)
  public func loadModels(_ models: AsrModels) async throws
  public var decoderLayerCount: Int                          // 2 for v3
  public func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
  public func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
  public func transcribe(_ buf: AVAudioPCMBuffer, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
  public func cleanup()   // nils models AND clears the GLOBAL sharedMLArrayCache
}
AsrModels.load(from: URL, configuration: MLModelConfiguration? = nil, version: .v3,
               encoderPrecision: .int8, encoderComputeUnits: MLComputeUnits? = nil, progressHandler:) async throws -> AsrModels
AsrModels.download(to: URL? = nil, force: false, version: .v3, encoderPrecision: .int8, progressHandler:) async throws -> URL
AsrModels.downloadAndLoad(...)                    // download + load in one call; also fetches vocab (#748)
AsrModels.modelsExist(at: URL, version: .v3) -> Bool
AsrModels.defaultCacheDirectory(for: .v3) -> URL
TdtDecoderState.make(decoderLayers: Int)          // fatalError on alloc failure
ASRResult { text, confidence: Float, duration, processingTime, tokenTimings: [TokenTiming]? }
TokenTiming { token: String, tokenId, startTime, endTime: TimeInterval, confidence: Float }
Language(rawValue: "pl")                          // .polish etc. Script filter, v3 only
TextNormalizer.shared.normalizeSentence(String)   // NeMo ITN, ENGLISH ONLY
AudioConverter().resampleAudioFile(URL) -> [Float] // any file to 16 kHz mono Float32
ModelHub.download(_ repo: Repo, to: URL, variant: String?, additionalModelNames: Set<String>, progressHandler:)
ProgressHandler = @Sendable (DownloadProgress) -> Void   // called on arbitrary queue
DownloadProgress { fractionCompleted, phase: .listing | .downloading(completedFiles:totalFiles:) | .compiling(modelName:) }
```
- The old download path: `ModelHub.download(.parakeetV3, to: cacheDir.deletingLastPathComponent(), variant: "int8", additionalModelNames: ["parakeet_vocab.json"], ...)`, then `AsrModels.load(...)` to force the on-device compile ("Optimizing model for your device", indeterminate spinner). ModelHub reports download in 0...0.5 and compile in 0.5...1, so the old code multiplied by 2 for the network phase. **Simpler for the rewrite: `AsrModels.download(version: .v3, progressHandler:)` then `AsrModels.load(...)`.**
- Default compute units: preprocessor `.cpuOnly`, rest `.cpuAndNeuralEngine` (no GPU). `encoderComputeUnits: .cpuAndGPU` gives about +8% throughput per FluidAudio docs. Not needed.

### 3.3 Audio format and length rules
- Recorder output: 16 000 Hz, mono, Int16 signed packed LE (`kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked`, 2 bytes/frame). The same bytes go to the WAV and to `onAudioChunk` (one chunk per render callback, about 10 ms).
- ASR wants `[Float]` 16 kHz mono in [-1, 1]. Conversion: `Float(Int16(littleEndian: s)) / 32767`, clamped.
- `ASRConstants`: `sampleRate 16000`, `maxModelSamples 240_000` (15 s), `minimumAudioDurationSeconds 0.3`, so fewer than 4800 samples throws `ASRError.invalidAudioData`. **Always pad short audio**. The old code appends 16 000 zeros (1 s) to every streaming slice and tail. The comment says that also helps capture final punctuation.
- ≤ 15 s: the input is **padded to a fixed 240 000 samples**, so every pass costs one full 15 s encoder run regardless of length. More than 15 s: internal `ChunkProcessor` (11 s chunks + 2 s context). URL input more than 480 000 samples (30 s): disk-backed chunking.
- Use a **fresh `TdtDecoderState` per independent pass**. Never reuse it across overlapping re-transcriptions.

### 3.4 Realtime algorithm (FluidAudioStreamingProvider + WordAgreementEngine)
- `AgreementConfig`: `transcribeIntervalSeconds 1.0`, `tokenConfirmationsNeeded 3`, `minWordsToConfirm 5`, `minPassConfidence 0.15`, `minWordConfidence 0.6`.
- Pass gating: skip if fewer than 4800 new samples since the last pass, or a pass is already running (`isTranscribing`).
- Seek point = `hypothesisStartTime > 0 ? hypothesisStartTime : confirmedEndTime` (seconds, absolute). Words get `timeOffset = seekSample/16000`.
- Confirmation needs: same longest common prefix (normalized: lowercase, `-` to space, letters/digits only) across passes with ≥ 5 words, for **3 consecutive passes**, **and** ≥ 3 sentence enders `. ! ? ;` in that prefix. It confirms up to the 3rd-from-last ender (the last 2 sentences stay hypothesis). The last 3 confirmed words must all have confidence ≥ 0.6.
- Consequence: confirmation only happens in long dictations (roughly 3+ sentences held stable for 3 s). `stopDisposition` = batch fallback when fewer than 3 segments were confirmed. **So for normal dictations the realtime text is display only, and the final is a clean batch pass over the WAV (about 0.1-0.3 s on ANE).** Keep this design: it gives accurate final text with no tail loss.
- Partial shown = confirmed words + current hypothesis (cumulative `fullText`).

### 3.5 Threading
- `AsrManager` is an `actor`. `AsrModels` is `Sendable` and was shared by 2-3 managers (streaming, batch, prewarm) at once. That worked, but the rewrite should use **one owner**.
- Streaming provider is a plain class: audio buffer under `NSLock`, `confirmedSegmentCount` under a second lock, loop in an unstructured `Task` with `Task.sleep(1s)`.
- Chunk ingress: `AsyncStream<Data>` with `.bufferingOldest(2048)` (drops newest when full), fed from the CoreAudio thread through a `nonisolated` method. The send loop is `Task.detached`. Partial callback hops `Task { @MainActor in ... }` and is guarded by `startID` + `recordingState == .recording` so late partials after stop are dropped.
- `getOrLoadModels` dedupes concurrent loads with a stored `Task<AsrModels, Error>` keyed by version. Keep this: the prewarm, the recording-start preload and the streaming connect can race.

### 3.6 Native Apple (verdict: drop or trivial fallback)
- `SpeechAnalyzer(modules: [SpeechTranscriber(locale:, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])])`, `analyzeSequence(from: AVAudioFile)`, `finalizeAndFinish(through:)`, results via `for try await r in transcriber.results { text += String(r.text.characters) }`, timeout `max(20, dur*4+10)` s.
- Asset handling: `SpeechTranscriber.supportedLocale(equivalentTo:)`, `installedLocales` (preferred over `AssetInventory.status`, which "can become stale"), `AssetInventory.assetInstallationRequest(supporting:)`, `AssetInventory.reserve(locale:)` with a reservation-limit retry that releases one old locale.
- Gated by `#available(macOS 26, *)` and compile flag `ENABLE_NATIVE_SPEECH_ANALYZER`. Batch only, no streaming in this app.

### 3.7 whisper.cpp (verdict: drop)
- `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`, language C-string (nil for auto), `initial_prompt` = `TranscriptionPrompt` default ("Hello, how are you doing? Nice to meet you."), `n_threads` = max threads, optional Silero VAD (threshold 0.5, min speech 250 ms, min silence 100 ms, pad 30 ms). Reads the WAV by skipping a fixed 44-byte header. Nothing here is needed.

### 3.8 Known bugs and quirks to avoid
1. `ModelPrewarmService` builds its **own** `TranscriptionServiceRegistry`, so a second `FluidAudioTranscriptionService` loads a **second copy of AsrModels** that is never released (hundreds of MB). It only "helps" by warming the OS CoreML/ANE compile cache. Rewrite: prewarm the single shared engine.
2. `AsrManager.cleanup()` clears FluidAudio's **global** `sharedMLArrayCache`. Cleaning one manager while another transcribes causes needless reallocations. Rewrite: one long-lived `AsrManager`, and never call `cleanup` between dictations.
3. Live preview duplication: committed segments are ITN-normalized, but `fullText` partials are raw. The preview joins with `hasPrefix` and falls back to `prefix + " " + text`, so it duplicates confirmed text whenever ITN changed it. Rewrite: show the raw `fullText` only and normalize only the final text.
4. `TextNormalizer.normalizeSentence` = NeMo **English** ITN ("two hundred" to "200", "period" to "."). For Polish it is a costly near no-op with rare false hits. Rewrite: apply only when language == "en", or drop it.
5. `selectedLanguage = "auto"` means no `Language` hint. For a Polish speaker set `pl`, which gives `Language.polish` script filtering (FluidAudio issue #512: Cyrillic tokens in Latin-script Slavic).
6. Dictionary words (`VocabularyWord`) are **never** fed to Parakeet. Only cloud and whisper use them. FluidAudio has CTC vocabulary boosting (`SlidingWindowAsrManager.configureVocabularyBoosting`, which needs an extra CTC model). For v1 of the rewrite, keep dictionary = post-transcription word replacement.
7. The streaming pass re-encodes up to 15 s every second (fixed-shape encoder). It is cheap on ANE, but do not lower the interval below ~0.5 s.

## 4. Code excerpts worth copying the idea of

Model load with dedupe (`FluidAudioTranscriptionService.swift`):
```swift
func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
    if let cached = cachedModels, cached.version == version { return cached }
    if let (v, task) = loadingTask, v == version { return try await task.value }
    let task = Task {
        let dir = AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: dir, version: version) else {
            throw AsrModelsError.loadingFailed("Parakeet model files are incomplete. Download the model from AI Models.")
        }
        return try await AsrModels.load(from: dir, configuration: nil, version: version, encoderPrecision: .int8)
    }
    loadingTask = (version, task)
    defer { if loadingTask?.version == version { loadingTask = nil } }
    let models = try await task.value
    cachedModels = models
    return models
}
// batch:
var state = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
let result = try await asrManager.transcribe(audioURL, decoderState: &state, language: Language(rawValue: lang)) // nil for "auto"
```

One streaming pass (`FluidAudioStreamingProvider.runTranscriptionPass`, condensed):
```swift
let seekTime = agreement.hypothesisStartTime > 0 ? agreement.hypothesisStartTime : agreement.confirmedEndTime
let seekSample = max(0, Int(seekTime * 16_000))
var slice = Array(buffer[max(0, seekSample - trimmedSampleCount)...])   // under lock
slice += [Float](repeating: 0, count: 16_000)                           // 1 s silence pad
var state = TdtDecoderState.make(decoderLayers: decoderLayerCount)        // fresh every pass
let r = try await asrManager.transcribe(slice, decoderState: &state, language: languageHint)
guard let timings = r.tokenTimings, !timings.isEmpty else { emit(.partial(r.text)); return }
let words = WordAgreementEngine.mergeTokensToWords(timings, timeOffset: Double(seekSample) / 16_000)
let a = agreement.processTranscriptionResult(words: words, resultConfidence: r.confidence)
if !a.newlyConfirmedText.isEmpty { confirmedSegments += 1; emit(.committed(a.newlyConfirmedText)) }
if !a.fullText.isEmpty { emit(.partial(a.fullText)) }
// drop audio before the first unconfirmed word
let trimTo = Int(agreement.hypothesisStartTime * 16_000) - trimmedSampleCount
if agreement.hypothesisStartTime > 0, trimTo > 0 { buffer.removeFirst(min(trimTo, buffer.count)); trimmedSampleCount += ... }
```

Token-to-word merge (SentencePiece `▁` marks a word start):
```swift
for t in timings {
    if t.token.hasPrefix("▁") || t.token.hasPrefix(" ") {
        if !cur.isEmpty { words.append(TimedWord(text: cur, start: s + off, end: e + off, conf: avg(confs))) }
        cur = t.token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "▁", with: "")
        s = t.startTime; e = t.endTime; confs = [t.confidence]
    } else {
        if cur.isEmpty { s = t.startTime }
        cur += t.token; e = t.endTime; confs.append(t.confidence)
    }
}   // flush last word after the loop
```

Agreement core (`WordAgreementEngine.processTranscriptionResult`, condensed):
```swift
if isFirstPass { isFirstPass = false; previous = words; return result(hyp: words) }
if passConfidence < 0.15 { agreeCount = 0; previous = words; return result(hyp: words) }
let prefix = longestCommonPrefix(words, previous)   // compares normalizedText
previous = words
guard prefix.count >= 5 else { agreeCount = 0; return result(hyp: words) }
agreeCount += 1
guard agreeCount >= 3 else { return result(hyp: words) }
// punctuation rule: need >= 3 sentence enders in the prefix; cut after the 3rd-from-last
let enders = prefix.indices.filter { ".!?;".contains(prefix[$0].text.last ?? " ") }
guard enders.count >= 3, enders[enders.count - 3] + 1 >= 5 else { return result(hyp: words) }
let n = enders[enders.count - 3] + 1
guard (words.prefix(n).suffix(3).map(\.confidence).min() ?? 1) >= 0.6 else { return result(hyp: words) }
confirmed += words.prefix(n); confirmedEndTime = words[n - 1].endTime
let hyp = Array(words.dropFirst(n)); hypothesisStartTime = hyp.first?.startTime ?? confirmedEndTime
agreeCount = hyp.isEmpty ? 0 : 1; previous = hyp; isFirstPass = hyp.isEmpty
return result(hyp: hyp, newlyConfirmed: Array(words.prefix(n)))
```

Download progress (network phase only, then compile):
```swift
try await ModelHub.download(.parakeetV3, to: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent(),
    variant: "int8", additionalModelNames: ["parakeet_vocab.json"]) { p in
        let f = min(max(p.fractionCompleted * 2, 0), 1)   // ModelHub: 0...0.5 = network
        Task { @MainActor in ui.progress = f }             // handler runs on an arbitrary queue
}
ui.status = "Optimizing model for your device"            // indeterminate
_ = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v3), version: .v3, encoderPrecision: .int8)
```

## 5. Recommended minimal design for VocaType 2

- **One engine only: Parakeet TDT 0.6b v3** (`AsrModelVersion.v3`, int8 encoder). Cloud fallback (Groq/Gemini) lives in the cloud note. No whisper, no native Apple, no Nemotron or Unified for v1.
- `ParakeetModelStore` (@MainActor, @Observable): `isInstalled` (`AsrModels.modelsExist`), `download()` with a progress enum (`.downloading(Double)`, `.optimizing`, `.ready`, `.failed`), `delete()`. It reuses the existing `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` (app must stay unsandboxed).
- `ParakeetEngine` (actor, app-wide singleton): owns ONE `AsrModels` + ONE `AsrManager`, has a deduped `load()`, `prewarm()` (transcribe 1 s of zeros; no bundled wav needed) called at launch + `NSWorkspace.didWakeNotification` + after download, `transcribe(samples:[Float], language:) -> ASRResult` and `transcribe(url:language:) -> String`. Never `cleanup()` between dictations. Only on model delete or memory pressure.
- `LivePreviewTranscriber` (actor per recording): `append(pcm16: Data)` (lock-free append inside the actor), a 1 s loop that runs the agreement pass through `ParakeetEngine`, and exposes `AsyncStream<String>` of preview text (`fullText`). Port `WordAgreementEngine` 1:1 (it is small and correct). Pad slices with 1 s of zeros, use a fresh decoder state per pass, and trim the buffer at `hypothesisStartTime`.
- `stop()` on the live transcriber: if `confirmedSegments >= 3`, return confirmed + tail pass; else return `nil`, which means the caller batch-transcribes the WAV. Simplest variant (recommended): **always batch the full WAV on stop** and use streaming only for the preview. Re-encoding 60 s is about 6 fixed 15 s encoder windows (11 s chunks + 2 s context) on ANE, typically well under 1 s. Then drop the commit/timeout machinery entirely.
- Audio handoff: the recorder emits Int16 16 kHz mono `Data`, and a `Sendable` sink (`AsyncStream<Data>`, `.bufferingOldest(4096)`) feeds the preview actor. Buffer chunks until the model is ready instead of blocking recording start.
- Preview UI: `@MainActor` view model `partialText`, updates dropped unless state == `.recording`, fixed-height (~56 pt) bottom-anchored scroll with a top fade and no animation. Clear it on stop.
- Post-processing on the final only: strip `[..]`, `(..)`, `{..}`, collapse whitespace, then dictionary replacements. ITN only if language == "en" (or skip).
- Settings: a single language picker (`auto` or one of the 25 codes: bg cs da de el en es et fi fr hr hu it lt lv mt nl pl pt ro ru sk sl sv uk), default `pl` for this user, mapped to `Language(rawValue:)`. A single "live preview" toggle (default on).
- Package: `FluidAudio` pinned to a release tag. Platform macOS 14+, Apple Silicon required (`AsrModels.isModelValid` throws on Intel).

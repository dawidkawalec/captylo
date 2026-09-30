# FluidAudio research for VocaType 2.0 (Parakeet TDT v3, batch + live preview)

Source of truth: a local clone of `FluidInference/FluidAudio` at HEAD `21493f8` (= tag **v0.17.4**, 2026-09-24),
read directly from `Sources/FluidAudio/...`. I also compiled and ran every snippet below against the user's
existing model cache (probe: `scratchpad/fa-probe`, Swift 6.3.3, Xcode 26.6, M3 Pro, Swift 6 language mode, no warnings).

## 1. Version, pinning, platform

| Item | Value |
|---|---|
| Latest tag / GitHub "latest release" | **v0.17.4** (published 2026-09-25T00:08Z, not prerelease). HEAD of `main` == v0.17.4 today |
| Old app pin | `main` @ `88d6d8166880dee1ac7c32c80f8e10cd782f8ca8` (2026-07-25) = `v0.15.5-28-g88d6d81`, 89 commits behind |
| Recommended SPM pin | `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")` (or `.upToNextMinor(from: "0.17.4")`). Pin a tag, not `branch: main` like the old app |
| Minimum OS | `platforms: [.macOS(.v14), .iOS(.v17)]` in Package.swift. Parakeet needs Apple Silicon (`AsrModels.isModelValid` throws `unsupportedPlatform` on Intel) |
| Manifest | `swift-tools-version: 6.0` (+ `Package@swift-6.2.swift` with traits) |
| Binary dependency | `NemoTextProcessing.xcframework` (Rust ITN engine, ~87 MB zip, text-processing-rs v0.3.1) is linked by default. On tools 6.2+ it is the opt-out trait `NemoTextProcessing` (`.package(url:..., traits: [])`). SwiftPM still *fetches* the zip even with the trait off. Whether the Xcode 26 UI can turn traits off is unverified; if not, a small local wrapper package can |

API drift pinned rev -> v0.17.4 for everything we use is **additive only** (checked by diffing `public` lines):
`AsrModels.loadLocal`, `AsrModelVersion.isV3Family`, `.redux`, `.ultra`, `ParakeetEncoderPrecision.int8V2`,
`ctcDetectedTerms/ctcAppliedTerms` on updates, `configureVocabularyBoosting` on Unified managers. Nothing removed.
Between them are many streaming/seam fixes (#855, #897, #905, #909) and the v3 long-form default change (#869).

**The docs are stale**: `Documentation/ASR/GettingStarted.md` still shows `asrManager.configure(models:)` and
`transcribe(samples, source: .system)`. Neither exists in 0.17.4. Use the signatures below.

## 2. Model cache path (important for migration)

- `AsrModels.defaultCacheDirectory(for: .v3)` = `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV3)`
  = `~/Library/Application Support/FluidAudio/Models/` + `Repo.parakeetV3.folderName`.
- `folderName` strips the `-coreml` suffix, so **v3 lives in `.../Models/parakeet-tdt-0.6b-v3`**, NOT `...-v3-coreml`.
- The user has both folders (461 MB each):
  - `parakeet-tdt-0.6b-v3/` (2026-08-16, written by the old app): `Preprocessor`, `Encoder`, `Decoder`,
    **`JointDecisionv3.mlmodelc`**, `parakeet_vocab.json`, `parakeet_v3_vocab.json`, `config.json`.
    This is complete for v0.17.4 int8: `AsrModels.modelsExist(at:version:.v3)` returned **true**, and it loaded with `ModelHub.offlineMode = true`.
  - `parakeet-tdt-0.6b-v3-coreml/` (2026-05-26): legacy layout from an older FluidAudio (`JointDecision.mlmodelc`, no `v3` joint).
    **Unused by v0.17.4**. It could be deleted to free 461 MB, but only if the user agrees.
- v3 int8 required files: `Preprocessor.mlmodelc`, `Encoder.mlmodelc` (6-bit LUT, "int8" precision), `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, and `parakeet_vocab.json`.
- The path uses `FileManager.urls(for: .applicationSupportDirectory, ...)`. The old app is **not sandboxed**
  (`com.apple.security.app-sandbox = false`), so the shared cache is visible. If VocaType 2.0 turns the sandbox on, this resolves
  inside `~/Library/Containers/<bundle>/Data/...` and the models download again. Stay unsandboxed, or pass an explicit directory.
- Other folder names if needed later: Ultra -> `parakeet-ultra`, v2 -> `parakeet-tdt-0.6b-v2`, VAD -> `silero-vad`.

## 3. Exact Swift signatures (v0.17.4)

### Models (`ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift`)
```swift
public enum AsrModelVersion: Sendable { case v2, v3, redux, ultra, tdtCtc110m, tdtJa
    public var decoderLayers: Int; public var isV3Family: Bool; public var hasFusedEncoder: Bool }
public enum ParakeetEncoderPrecision: String, Sendable, CaseIterable { case int8; case int8V2 = "int8-v2"; case int4 }

public struct AsrModels: Sendable {
    public let version: AsrModelVersion; public let vocabulary: [Int: String]; /* encoder/preprocessor/decoder/joint MLModels */
    public static func defaultCacheDirectory(for version: AsrModelVersion = .v3) -> URL
    public static func modelsExist(at directory: URL, version: AsrModelVersion,
                                   encoderPrecision: ParakeetEncoderPrecision = .int8) -> Bool
    @discardableResult
    public static func download(to directory: URL? = nil, force: Bool = false, version: AsrModelVersion = .v3,
                                encoderPrecision: ParakeetEncoderPrecision = .int8,
                                progressHandler: ProgressHandler? = nil) async throws -> URL
    public static func load(from directory: URL, configuration: MLModelConfiguration? = nil,
                            version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8,
                            encoderComputeUnits: MLComputeUnits? = nil,
                            progressHandler: ProgressHandler? = nil) async throws -> AsrModels
    public static func downloadAndLoad(to directory: URL? = nil, configuration: MLModelConfiguration? = nil,
                                       version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8,
                                       encoderComputeUnits: MLComputeUnits? = nil,
                                       progressHandler: ProgressHandler? = nil) async throws -> AsrModels
    public static func loadLocal(from directory: URL, version: AsrModelVersion = .v3, configuration: MLModelConfiguration? = nil,
                                 encoderPrecision: ParakeetEncoderPrecision = .int8,
                                 encoderComputeUnits: MLComputeUnits? = nil) throws -> AsrModels   // exact dir, never downloads
    public static func isModelValid(version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8) async throws -> Bool
}
```
Note: `load(from:)` goes through `ModelHub.loadModels`, so it **downloads any missing file** unless `ModelHub.offlineMode = true`
(`public static var offlineMode: Bool` on `ModelHub`). Pass the version folder itself (`defaultCacheDirectory(for:)`), because it internally
resolves `directory.deletingLastPathComponent()/<folderName>`.

### Download progress (`Shared/Download/DownloadTypes.swift`)
```swift
public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void
public struct DownloadProgress: Sendable { public let fractionCompleted: Double; public let phase: DownloadPhase }
public enum DownloadPhase: Sendable { case listing; case downloading(completedFiles: Int, totalFiles: Int); case compiling(modelName: String) }
// Low level: repo-wide download, one progress sequence (download = 0...0.5, CoreML compile = 0.5...1.0)
public static func ModelHub.download(_ repo: Repo, to directory: URL, variant: String? = nil,
                                     additionalModelNames: Set<String> = [], config: DownloadConfig = .default,
                                     progressHandler: ProgressHandler? = nil) async throws
```
Caveat: `AsrModels.download` calls `ModelHub.loadModels` once per component (4 calls), so its progress restarts from 0 for each file.
For a single smooth bar, do what the old app did: `ModelHub.download(.parakeetV3, to: defaultCacheDirectory(for: .v3).deletingLastPathComponent(), variant: "int8", additionalModelNames: [ModelNames.ASR.vocabularyFile], progressHandler:)`,
then `AsrModels.load`. Map `fractionCompleted * 2` to the network phase and show "Optimizing..." (indeterminate) during the first load.

### Batch transcription (`AsrManager.swift`, `public actor AsrManager`)
```swift
public init(config: ASRConfig = .default, models: AsrModels? = nil)
public func loadModels(_ models: AsrModels) async throws
public var decoderLayerCount: Int { get }            // 2 for v3
public var isAvailable: Bool { get }
public func transcribe(_ audioSamples: [Float], decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
public func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
public func transcribe(_ audioBuffer: AVAudioPCMBuffer, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
public func transcribeDiskBacked(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
public var transcriptionProgressStream: AsyncThrowingStream<Double, Error> { get async }  // only for > 15 s input
public func reset()      // clears the shared MLMultiArray cache
public func cleanup()    // drops model refs; manager unusable until loadModels again

public struct TdtDecoderState: Sendable { public static func make(decoderLayers: Int = 2) -> TdtDecoderState }
public struct ASRResult: Codable, Sendable { text: String; confidence: Float; duration; processingTime;
                                             tokenTimings: [TokenTiming]?; performanceMetrics; ctcDetectedTerms; ctcAppliedTerms; rtfx }
public struct TokenTiming: Codable, Sendable { token: String; tokenId: Int; startTime: TimeInterval; endTime: TimeInterval; confidence: Float }
public enum Language: String, Sendable, CaseIterable { case english = "en", polish = "pl", german = "de", ... }  // Shared/TokenLanguageFilter.swift
public enum ASRConstants { public static let sampleRate = 16_000; public static let maxModelSamples = 240_000 /* 15 s */;
                           public static let minimumAudioDurationSeconds = 0.3; public static func minimumRequiredSamples(forSampleRate:) -> Int }
public final class AudioConverter: Sendable { public init(targetFormat: AVAudioFormat? = nil, debug: Bool = false)
    public func resampleAudioFile(_ url: URL) throws -> [Float]; public func resampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> [Float]
    public func resample(_ samples: [Float], from inputRate: Double) throws -> [Float] }   // -> 16 kHz mono Float32
```
- Input shorter than 0.3 s throws `ASRError.invalidAudioData`. Guard it, or pad with silence (the old app appends 1 s of silence, which also helps the model add final punctuation).
- `language:` is a script filter for v3 (it skips wrong-script top-K tokens, for example Cyrillic when speaking Polish). There is no "auto" case; pass `nil` for auto.
- Input up to 15 s is a single encoder pass. Longer `[Float]` input is chunked automatically (`ChunkProcessor`, 11+2+2 s windows, v3 "no-mel" long-form path).
- Use a fresh `TdtDecoderState.make(...)` per independent utterance.

### Library streaming: `SlidingWindowAsrManager` (`public actor`) = TDT pseudo-streaming
```swift
public init(config: SlidingWindowAsrConfig = .default)
public func loadModels(_ models: AsrModels) async throws              // reuse already loaded models (~5 ms)
public func loadModels(to directory: URL? = nil, progressHandler: ProgressHandler? = nil) async throws  // downloadAndLoad(.v3)
public func startStreaming(source: AudioSource = .microphone) async throws
public func streamAudio(_ buffer: AVAudioPCMBuffer)                    // any format, resampled internally
public var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate> { get }  // subscribe before startStreaming
public private(set) var volatileTranscript: String; public private(set) var confirmedTranscript: String
public func finish() async throws -> String
public func reset() async throws; public func cancel() async; public func cleanup() async
public func configureVocabularyBoosting(vocabulary: CustomVocabularyContext, ctcModels: CtcModels, config: VocabularyRescorer.Config? = nil) async throws
public struct SlidingWindowAsrConfig: Sendable { static let `default`, streaming   // 11 s chunk + 2 s left + 2 s right
    public func applying(language: Language?) -> SlidingWindowAsrConfig; public func applying(tdtConfig: TdtConfig) -> SlidingWindowAsrConfig }
public struct SlidingWindowTranscriptionUpdate: Sendable { text: String; isConfirmed: Bool; confidence: Float; timestamp: Date;
                                                           tokenIds: [Int]; tokenTimings: [TokenTiming]; ctcDetectedTerms; ctcAppliedTerms }
```
**Not suitable for dictation partials**: the first window is decoded only after `chunk + right = 13 s` of audio.
`hypothesisChunkSeconds` is stored but never used in v0.17.4, so a typical dictation shorter than 13 s produces **no update until `finish()`**.
Each instance is **single-use**: `finish()`/`cancel()` close its input stream and `reset()` does not reopen it, so create a new manager per recording.
The probe run also showed a seam artifact in the final text ("... oraz. interpunkcję").

### True streaming engines (`StreamingAsrManager` protocol) are not a fit for Polish
- `StreamingUnifiedAsrManager` / `UnifiedAsrManager` (Parakeet Unified 0.6B), `StreamingNemotronAsrManager`, `StreamingEouAsrManager`: **English only**.
- `StreamingNemotronMultilingualAsrManager`: its docs list about 40 languages (en, es, de, fr, it, pt, ar, ja, ko, zh, ru, hi, vi, ...) without naming Polish. Polish support is unverified.
- Protocol: `loadModels()`, `appendAudio(_:)`, `processBufferedAudio()`, `finish() -> String`, `reset()`, `cleanup()`, `setPartialTranscriptCallback(_:)`, `getPartialTranscript()`.
- Parakeet TDT v3 (and Ultra) is the Polish-capable model (25 European languages), so for live text we build the loop in section 4.

### Extras
- `TextNormalizer.shared.normalizeSentence(_:)` (ITN, NeMo FST, English-centric) returned Polish text **unchanged** in the probe. v3 already writes "dwadzieścia pięć" as "25" itself. For a Polish-first app, ITN adds nothing and pulls in the 87 MB binary, so drop it unless English ITN is wanted.
- Custom vocabulary (CTC rescoring) for 0.6B v2/v3 needs a separate Parakeet CTC 110M encoder (about 97.5 MB, English-trained). It is unlikely to help Polish (not tested). For the app dictionary ("Słownik"), use app-side replacement rules plus an optional LLM prompt instead.
- `AsrModelVersion.ultra` (`parakeet-ultra`, 595 MB int8 encoder, macOS 14+): same API and languages, lower FLEURS WER in all 24 languages measured (mean 11.67 % vs v3 14.81 %), same speed. It is a one-line switch later, but a new ~630 MB download. Keep v3 as the default because it is already on disk.

## 4. Minimal working code (compiled + run, Swift 6 mode)

```swift
import AVFoundation
import FluidAudio

/// One engine for the whole app: load once, reuse for preview passes and the final pass.
actor ParakeetEngine {
    static let version: AsrModelVersion = .v3
    static var cacheDir: URL { AsrModels.defaultCacheDirectory(for: version) }   // .../FluidAudio/Models/parakeet-tdt-0.6b-v3
    static var isDownloaded: Bool { AsrModels.modelsExist(at: cacheDir, version: version) }

    private var asr: AsrManager?

    /// Download if missing. It does nothing when the files already exist.
    func download(progress: ProgressHandler? = nil) async throws {
        try await AsrModels.download(version: Self.version, progressHandler: progress)
    }

    /// First load on a machine about 28 s (CoreML ANE compile), then about 0.3 s. Call at app launch / warm-up.
    func load() async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.load(from: Self.cacheDir, version: Self.version)  // int8 encoder default
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    /// Batch: 16 kHz mono Float32 samples (use AudioConverter.resampleBuffer / resampleAudioFile to get them).
    func transcribe(_ samples: [Float], language: Language? = .polish) async throws -> ASRResult? {
        guard let asr else { throw ASRError.notInitialized }
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate) else { return nil }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state, language: language)
    }

    /// Live preview: decode only the last <= 15 s (single encoder pass, about 40-95 ms on M3 Pro).
    func preview(_ buffer: [Float], language: Language? = .polish) async throws -> String {
        try await transcribe(Array(buffer.suffix(ASRConstants.maxModelSamples)), language: language)?.text ?? ""
    }

    func release() async {
        await asr?.cleanup()
        asr = nil
    }
}

// Recording session (sketch): mic tap -> 16 kHz Float32 -> append to `buffer`.
// Every ~1 s of new audio: `partial = try await engine.preview(buffer)` -> show in the widget
// (drop the pass if the previous one is still running).
// On stop: cancel the preview task, then `final = try await engine.transcribe(buffer)` over the full audio
// (> 15 s is chunked automatically) -> paste. There is no agreement engine or token-timing merge.
```

The actor above is `fa-probe/Sources/Probe/Engine.swift`. It compiled with no warnings in Swift 6 mode and ran correctly:
preview of the first 3 s, the full final pass, and `nil` for input under 0.3 s.
The probe (`fa-probe/Sources/Probe/main.swift`) runs the same calls plus `SlidingWindowAsrManager`:
```swift
let sw = SlidingWindowAsrManager(config: SlidingWindowAsrConfig.streaming.applying(language: .polish))
try await sw.loadModels(models)
let updates = await sw.transcriptionUpdates
let listener = Task { for await u in updates { print(u.isConfirmed, u.text) } }
try await sw.startStreaming(source: .microphone)
await sw.streamAudio(pcmBuffer)            // repeat per mic buffer
let final = try await sw.finish(); listener.cancel(); await sw.cleanup()
```

## 5. Measured on this Mac (M3 Pro, release build, user's cached v3)

| Step | Result |
|---|---|
| `AsrModels.load` first run of a new binary | **27.6 s** (CoreML specialization; show "Optimizing model" once) |
| `AsrModels.load` warm | **0.28 s**; `AsrManager.loadModels` 4-5 ms |
| Batch PL 11.6 s clip | **107-119 ms**, confidence 0.97 |
| Batch EN 8.5 s clip | 81 ms |
| Preview pass per second of audio (1-11 s tail) | 39-91 ms, final full pass 95 ms |
| SlidingWindow on 23 s of audio | first update only after 13 s; `finish()` 286 ms |

Transcript quality (macOS `say -v Zosia` TTS, so the audio is synthetic): Polish text and punctuation were good, and "dwadzieścia pięć" came out as "25".
Brand names came out wrong ("VocaType" became "w ocatypy", "Parakeet" became "Paracet"), so the Słownik replacement rules are needed.

## 6. Old app usage vs what VocaType 2.0 needs

The old app (`VoiceInk/Transcription/FluidAudio/*`, `Transcription/Streaming/FluidAudio*Provider.swift`, `WordAgreementEngine.swift`) uses:
`AsrManager(config: .default)`, `loadModels(_:)`, `transcribe(_ url/samples:, decoderState:&, language:)`, `TdtDecoderState.make`,
`AsrModels.defaultCacheDirectory/modelsExist/load(from:configuration:version:encoderPrecision: .int8)`,
`ModelHub.download(.parakeetV3, to:, variant: "int8", additionalModelNames: [ModelNames.ASR.vocabularyFile], progressHandler:)`,
`AsrModelsError`, `ASRError.notInitialized`, `ASRConstants.minimumRequiredSamples`, `TextNormalizer.shared.normalizeSentence`,
plus Unified (`UnifiedAsrManager`, `StreamingUnifiedAsrManager`, `UnifiedConfig`, `ModelNames.ParakeetUnified`) and Nemotron
(`StreamingNemotronMultilingualAsrManager.downloadVariant/languageDirectory/setLanguage/process/finish`). **All of it still compiles against v0.17.4** (additive drift only).

What to keep and what to drop for 2.0:
- Keep: v3 only, the batch path, one `AsrManager` actor loaded once and kept warm, and a fresh decoder state per call.
- Replace the roughly 430-line `FluidAudioModelManager` with `modelsExist` + `download` (or `ModelHub.download` for a smooth bar) + `load`.
- Replace `FluidAudioStreamingProvider` + `WordAgreementEngine` (a 1 s timer, agreement confirmation, buffer trimming, a batch fallback) with the tail-preview loop above. The final text always comes from one full batch pass, which is fast (about 0.1 s for 12 s of audio) and avoids all the seam and merge bugs.
- Drop: v2, Unified, Nemotron, Cohere/other engines, ITN (see above), and CTC vocabulary boosting.
- Warm-up: call `engine.load()` at launch in the background, so the first dictation does not pay the load cost. The 28 s first-run compile happens once per app binary or OS update; the onboarding should cover it ("Preparing the model...").

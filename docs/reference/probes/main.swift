@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// Probe for VocaType 2.0 port notes: verifies FluidAudio v0.17.4 API against the
// user's existing cache (~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3).

let audioDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "audio")

func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

// 1) Model cache + load (no network: fail loudly if the cache is incomplete)
ModelHub.offlineMode = true
let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
print("cacheDir:", cacheDir.path)
print("modelsExist:", AsrModels.modelsExist(at: cacheDir, version: .v3))

var t = Date()
let models = try await AsrModels.load(from: cacheDir, version: .v3)  // encoderPrecision: .int8 default
print("AsrModels.load:", ms(t))

let asr = AsrManager(config: .default)
t = Date()
try await asr.loadModels(models)
print("AsrManager.loadModels:", ms(t), "decoderLayers:", await asr.decoderLayerCount)

// 2) Batch: [Float] 16 kHz mono
let converter = AudioConverter()
for (name, lang) in [("pl", Language.polish), ("en", Language.english)] {
    let samples = try converter.resampleAudioFile(audioDir.appendingPathComponent("\(name).wav"))
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    t = Date()
    let r = try await asr.transcribe(samples, decoderState: &state, language: lang)
    print("[batch \(name)] \(String(format: "%.1f", Double(samples.count) / 16000))s audio in \(ms(t)) conf=\(r.confidence)")
    print("   text:", r.text)
    print("   ITN :", TextNormalizer.shared.normalizeSentence(r.text), "(native:", TextNormalizer.shared.isNativeAvailable, ")")
}

// 3) Live-preview loop (recommended for dictation): re-transcribe the growing buffer
//    tail every ~1 s with a fresh decoder state, then one final full pass at stop.
do {
    let pl = try converter.resampleAudioFile(audioDir.appendingPathComponent("pl.wav"))
    var buffer: [Float] = []
    var lastPass = 0
    let chunk = 1_600  // 100 ms mic callback
    var i = 0
    while i < pl.count {
        buffer.append(contentsOf: pl[i..<min(i + chunk, pl.count)])
        i += chunk
        if buffer.count - lastPass >= 16_000 {  // every 1 s of new audio
            lastPass = buffer.count
            let tail = Array(buffer.suffix(ASRConstants.maxModelSamples))  // <= 15 s single window
            var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let tp = Date()
            let partial = try await asr.transcribe(tail, decoderState: &st, language: .polish)
            print("[preview \(buffer.count / 16000)s] (\(ms(tp))) \(partial.text)")
        }
    }
    var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    t = Date()
    let final = try await asr.transcribe(buffer, decoderState: &st, language: .polish)
    print("[preview final] (\(ms(t))) \(final.text)")
}

// 4) Library streaming: SlidingWindowAsrManager (single-use per session)
do {
    let sw = SlidingWindowAsrManager(config: SlidingWindowAsrConfig.streaming.applying(language: .polish))
    try await sw.loadModels(models)  // reuse loaded AsrModels, no reload from disk
    let updates = await sw.transcriptionUpdates  // subscribe BEFORE startStreaming
    let listener = Task {
        for await u in updates {
            print("[sliding \(u.isConfirmed ? "confirmed" : "volatile ")] \(u.text)")
        }
    }
    try await sw.startStreaming(source: .microphone)

    // Feed the Polish clip twice (~25 s) in 100 ms AVAudioPCMBuffers, like a mic tap would.
    t = Date()
    for _ in 0..<2 {
        let file = try AVAudioFile(forReading: audioDir.appendingPathComponent("pl.wav"))
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600) else { break }
            try file.read(into: buf, frameCount: 1_600)
            await sw.streamAudio(buf)
        }
    }
    let finalText = try await sw.finish()
    print("[sliding final] (\(ms(t))) \(finalText)")
    listener.cancel()
    await sw.cleanup()
}

// 5) Cleanup
await asr.cleanup()
print("done")

// 6) ParakeetEngine actor (the code sample from the notes)
do {
    let engine = ParakeetEngine()
    print("engine isDownloaded:", ParakeetEngine.isDownloaded)
    try await engine.load()
    let s = try AudioConverter().resampleAudioFile(audioDir.appendingPathComponent("pl.wav"))
    print("[engine preview]", try await engine.preview(Array(s.prefix(48_000))))
    print("[engine final]", try await engine.transcribe(s)?.text ?? "<nil>")
    print("[engine too short]", try await engine.transcribe(Array(s.prefix(2_000))) == nil)
    await engine.release()
}

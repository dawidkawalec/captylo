import AVFoundation
import FluidAudio

/// One engine for the whole app: load once, reuse for preview passes and the final pass.
actor ParakeetEngine {
    static let version: AsrModelVersion = .v3
    static var cacheDir: URL { AsrModels.defaultCacheDirectory(for: version) }
    static var isDownloaded: Bool { AsrModels.modelsExist(at: cacheDir, version: version) }

    private var asr: AsrManager?

    func download(progress: ProgressHandler? = nil) async throws {
        try await AsrModels.download(version: Self.version, progressHandler: progress)
    }

    func load() async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.load(from: Self.cacheDir, version: Self.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    func transcribe(_ samples: [Float], language: Language? = .polish) async throws -> ASRResult? {
        guard let asr else { throw ASRError.notInitialized }
        guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate) else { return nil }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state, language: language)
    }

    func preview(_ buffer: [Float], language: Language? = .polish) async throws -> String {
        try await transcribe(Array(buffer.suffix(ASRConstants.maxModelSamples)), language: language)?.text ?? ""
    }

    func release() async {
        await asr?.cleanup()
        asr = nil
    }
}

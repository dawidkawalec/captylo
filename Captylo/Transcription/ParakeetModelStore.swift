import FluidAudio
import Foundation
import Observation

/// Download, prewarm and delete state of the Parakeet model, observed by Modele and onboarding.
/// The model directory is shared with the old app (gotcha 23): the caller shows that warning before `delete()`.
@MainActor
@Observable
final class ParakeetModelStore {
    enum Status: Equatable, Sendable {
        case missing
        /// Progress 0...1 over the whole download (network + Core ML compile).
        case downloading(Double)
        /// Files on disk, the engine is loading (first load of a binary ~30 s, gotcha 16).
        case optimizing
        case ready
        case failed(String)
    }

    enum Failure: LocalizedError {
        case incompleteDownload

        var errorDescription: String? {
            switch self {
            case .incompleteDownload:
                return String(localized: "Pobrany model jest niekompletny. Spróbuj ponownie.")
            }
        }
    }

    static let downloadVariant = "int8"

    private(set) var status: Status = .missing
    @ObservationIgnored private let engine: ParakeetEngine
    /// Fixed status for the design preview; `refresh()` keeps it instead of reading the disk.
    @ObservationIgnored private let pinnedStatus: Status?

    init(engine: ParakeetEngine, pinnedStatus: Status? = nil) {
        self.engine = engine
        self.pinnedStatus = pinnedStatus
        refresh()
    }

    /// True when the files are on disk, whatever the engine state.
    var isInstalled: Bool { ParakeetEngine.isDownloaded }

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    /// Re-derives `status` from the files on disk and the engine state (no-op while downloading).
    func refresh() {
        if let pinnedStatus {
            status = pinnedStatus
            return
        }
        if isDownloading { return }
        guard ParakeetEngine.isDownloaded else {
            status = .missing
            return
        }
        switch engine.state {
        case .loading:
            status = .optimizing
        case .failed(let message):
            status = .failed(message)
        case .ready, .missing:
            status = .ready
        }
    }

    /// Downloads the int8 v3 files with one smooth progress bar, then loads (compiles) the model.
    func download() async {
        if isDownloading { return }
        status = .downloading(0)
        Log.transcription.info("Parakeet download started")
        do {
            let parent = AppPaths.parakeetModelDir.deletingLastPathComponent()
            try await ModelHub.download(
                .parakeetV3,
                to: parent,
                variant: Self.downloadVariant,
                additionalModelNames: [ModelNames.ASR.vocabularyFile]
            ) { progress in
                let fraction = min(max(progress.fractionCompleted, 0), 1)
                Task { @MainActor [weak self] in
                    self?.reportDownloadProgress(fraction)
                }
            }
            guard ParakeetEngine.isDownloaded else { throw Failure.incompleteDownload }
            status = .optimizing
            try await engine.load()
            status = .ready
            Log.transcription.info("Parakeet download finished")
        } catch {
            Log.transcription.error("Parakeet download failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Loads the model when the files exist (launch, wake, after download). `.optimizing` while it runs.
    func prewarm() async {
        if isDownloading { return }
        guard ParakeetEngine.isDownloaded else {
            status = .missing
            return
        }
        if engine.state != .ready {
            status = .optimizing
        }
        do {
            try await engine.load()
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Removes the shared model directory and releases the engine. The caller warns first (gotcha 23).
    func delete() throws {
        let directory = AppPaths.parakeetModelDir
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        status = .missing
        Task { await engine.unload() }
        Log.transcription.notice("Parakeet model deleted from \(directory.path, privacy: .public)")
    }

    private func reportDownloadProgress(_ fraction: Double) {
        guard isDownloading else { return }
        status = .downloading(fraction)
    }
}

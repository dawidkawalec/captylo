import Foundation
import Observation

/// Download, prewarm and delete state of the local Whisper model, observed by Modele and
/// onboarding. Also offers to remove the Parakeet model of earlier versions, whose folder is
/// shared with the old app (gotcha 23): the caller shows that warning before `deleteLegacyParakeet()`.
@MainActor
@Observable
final class LocalModelStore {
    enum Status: Equatable, Sendable {
        case missing
        /// Progress 0...1 over the model files.
        case downloading(Double)
        /// Files on disk, the engine is loading (the first load compiles for the Neural Engine, a few minutes).
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

    /// Download size shown before the download, in MB.
    static let downloadMB = 1_600

    private(set) var status: Status = .missing {
        didSet {
            if status == .optimizing {
                if optimizingSince == nil { optimizingSince = Date() }
            } else {
                optimizingSince = nil
            }
        }
    }
    /// When the current `.optimizing` began, for the elapsed time next to it; nil otherwise.
    private(set) var optimizingSince: Date?
    /// The Parakeet folder of earlier versions is still on disk.
    private(set) var hasLegacyParakeet = false
    /// Runs once a `download()` ends with the model loaded: the meeting voice detector is
    /// fetched right after it (`AppState`), so a first meeting never waits for a download.
    @ObservationIgnored var onDownloaded: (@MainActor () -> Void)?
    @ObservationIgnored private let engine: WhisperEngine
    /// Fixed status for the design preview; `refresh()` keeps it instead of reading the disk.
    @ObservationIgnored private let pinnedStatus: Status?

    init(engine: WhisperEngine, pinnedStatus: Status? = nil) {
        self.engine = engine
        self.pinnedStatus = pinnedStatus
        refresh()
    }

    /// True when the files are on disk, whatever the engine state.
    var isInstalled: Bool { WhisperEngine.isDownloaded }

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
        hasLegacyParakeet = FileManager.default.fileExists(atPath: AppPaths.legacyParakeetModelDir.path(percentEncoded: false))
        if isDownloading { return }
        guard WhisperEngine.isDownloaded else {
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

    /// Downloads the model with one progress bar, then loads (compiles) it. With the files already
    /// on disk (a load that failed, "Spróbuj ponownie") it only loads again, never re-fetches 1.6 GB.
    func download() async {
        if isDownloading { return }
        do {
            if !WhisperEngine.isDownloaded {
                status = .downloading(0)
                Log.transcription.info("Whisper download started")
                try await WhisperEngine.download { fraction in
                    Task { @MainActor [weak self] in
                        self?.reportDownloadProgress(fraction)
                    }
                }
            }
            guard WhisperEngine.isDownloaded else { throw Failure.incompleteDownload }
            status = .optimizing
            try await engine.load()
            status = .ready
            Log.transcription.info("Whisper download finished")
            onDownloaded?()
        } catch {
            Log.transcription.error("Whisper download failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Loads the model when the files exist (launch, wake, after download). `.optimizing` while it runs.
    func prewarm() async {
        if isDownloading { return }
        guard WhisperEngine.isDownloaded else {
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

    /// Releases the engine and removes the model files (after a running pass, see `deleteModel()`).
    func delete() async throws {
        try await engine.deleteModel()
        status = .missing
        Log.transcription.notice("Whisper model deleted")
    }

    /// Removes the Parakeet folder of earlier versions. The caller warns first (gotcha 23).
    func deleteLegacyParakeet() throws {
        let directory = AppPaths.legacyParakeetModelDir
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
        hasLegacyParakeet = false
        Log.transcription.notice("Legacy Parakeet model deleted from \(directory.path, privacy: .public)")
    }

    private func reportDownloadProgress(_ fraction: Double) {
        guard isDownloading else { return }
        status = .downloading(fraction)
    }
}

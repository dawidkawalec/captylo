import Accelerate
import Foundation

/// A live 16 kHz mono Float32 source for one meeting track.
protocol MeetingAudioSource: AnyObject, Sendable {
    /// Starts delivering samples on the source's own serial queue (never the real-time thread).
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
    /// Latest RMS (0...1) for the live bar.
    var level: Float { get }
}

enum MeetingAudioError: LocalizedError {
    case engine(String)
    case tap(OSStatus)
    case format

    var errorDescription: String? {
        switch self {
        case .engine(let message): return String(localized: "Nie udało się uruchomić mikrofonu: \(message)")
        case .tap(let status): return String(localized: "Nie udało się nagrać dźwięku systemu (kod \(Int(status))).")
        case .format: return String(localized: "Nieobsługiwany format dźwięku.")
        }
    }
}

enum AudioLevel {
    /// RMS scaled by 4 and clamped to 1, so normal speech fills most of the live bar.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length(samples.count)) }
        return min(1, rms * 4)
    }
}

import AVFoundation
import Foundation

/// Start / stop / error cues from `Resources/Sounds/<cue>.caf`, preloaded once.
/// Honors `AppSettings.sounds`; a missing resource is logged and the cue is skipped.
@MainActor
final class Sounds: SoundPlaying {
    private let settings: AppSettings
    private var players: [SoundCue: AVAudioPlayer] = [:]

    init(settings: AppSettings, bundle: Bundle = .main) {
        self.settings = settings
        for cue in SoundCue.allCases {
            guard let url = bundle.url(forResource: cue.resourceName, withExtension: "caf") else {
                Log.audio.error("Sound resource missing: \(cue.resourceName, privacy: .public).caf")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = Self.volume(for: cue)
                player.prepareToPlay()
                players[cue] = player
            } catch {
                Log.audio.error("Sound \(cue.resourceName, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Restarts the cue from the beginning; a no-op when sounds are off.
    func play(_ cue: SoundCue) {
        guard settings.sounds, let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }

    /// True when every cue loaded (diagnostics).
    var isFullyLoaded: Bool { players.count == SoundCue.allCases.count }

    private static func volume(for cue: SoundCue) -> Float {
        switch cue {
        case .start, .stop: return 0.3
        case .error: return 0.2
        }
    }
}

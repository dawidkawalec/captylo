/// The three sound cues shipped in `Resources/Sounds/<name>.caf`.
enum SoundCue: String, CaseIterable, Sendable {
    case start
    case stop
    case error

    /// Resource name without extension.
    var resourceName: String { rawValue }
}

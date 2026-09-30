/// Language picker values. `auto` is stored in settings and maps to `nil` on the engine side.
enum TranscriptionLanguages {
    static let auto = "auto"

    /// The 25 Parakeet v3 languages, ISO codes as accepted by FluidAudio `Language(rawValue:)`.
    static let codes: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// Settings value -> engine value (`auto` becomes nil).
    static func engineCode(for setting: String) -> String? {
        setting == auto ? nil : setting
    }
}

import Foundation

/// What the consent card hands the user to tell the others in a call that it is being noted.
enum MeetingConsent {
    /// Copied by "Skopiuj informację": one Polish and one English sentence, whatever the UI
    /// language, so it can go straight into any call's chat. Not in the string catalog on purpose.
    static let disclosure = """
    Dla wygody robię notatki z tej rozmowy w Captylo, nagranie zostaje na moim komputerze.
    I'm taking notes of this call with Captylo; the recording stays on my computer.
    """
}

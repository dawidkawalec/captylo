import SwiftUI

/// "Wykrywanie mowy do spotkań: gotowe" under the model status in Modele and onboarding: the
/// voice detector of the meetings downloads with the speech model. Nothing while no load was
/// attempted yet.
@MainActor
struct SpeechDetectorStatusLine: View {
    let status: SpeechDetectorStatus

    var body: some View {
        if let line = Self.line(for: status.state) {
            ToolStatusLine(text: line.text, tone: line.tone)
        }
    }

    static func line(for state: SpeechDetectorStatus.State) -> (text: String, tone: InlineStatus.Tone)? {
        switch state {
        case .missing:
            return nil
        case .loading:
            return (String(localized: "Wykrywanie mowy do spotkań: pobieram..."), .neutral)
        case .ready:
            return (String(localized: "Wykrywanie mowy do spotkań: gotowe"), .success)
        case .failed(let message):
            return (String(localized: "Wykrywanie mowy do spotkań: nie pobrano (\(message))"), .error)
        }
    }
}

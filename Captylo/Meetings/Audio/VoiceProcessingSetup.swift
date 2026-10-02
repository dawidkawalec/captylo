import Foundation

/// "Redukcja echa (eksperymentalna)": Apple's voice processing on the meeting mic (echo
/// cancellation, noise suppression, gain control). The engine work is a closure, so the
/// decision is pure and tests run it with a fake that throws: a refused input (some Bluetooth
/// outputs, error -10875) means the plain engine, never a failed recording.
enum VoiceProcessingSetup {
    enum Outcome: Equatable, Sendable {
        /// The switch is off: the plain engine.
        case off
        /// Voice processing runs on this engine.
        case on
        /// Wanted, but the input refused it: the plain engine, with the reason for the log.
        case unavailable(String)

        var isActive: Bool { self == .on }

        /// "on", "off" or "unavailable (reason)".
        var logLabel: String {
            switch self {
            case .off: return "off"
            case .on: return "on"
            case .unavailable(let reason): return "unavailable (\(reason))"
            }
        }
    }

    /// Runs `enable` when the switch is on; a throw is `unavailable`.
    static func apply(wanted: Bool, enable: () throws -> Void) -> Outcome {
        guard wanted else { return .off }
        do {
            try enable()
            return .on
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// The log line for a freshly built engine, nil when the previous build already said the
    /// same: one line at start, one more only when a rebuild changes the outcome.
    static func logMessage(_ outcome: Outcome, after previous: Outcome?) -> String? {
        guard outcome != previous else { return nil }
        return "Meeting mic voice processing: \(outcome.logLabel)"
    }
}

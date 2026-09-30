/// Persisted microphone choice. Stored as JSON under `AppSettings.Key.micSelection`.
/// Devices are identified by UID + model UID, never by `AudioDeviceID` (gotcha 30).
enum AudioInputSelection: Codable, Hashable, Sendable {
    case systemDefault
    case device(uid: String, modelUID: String)

    var isSystemDefault: Bool {
        if case .systemDefault = self { return true }
        return false
    }
}

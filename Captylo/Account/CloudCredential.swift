import Foundation

/// Where a cloud speech-to-text request goes and how it signs itself: the user's own key to the
/// vendor, or the Pro session to the Captylo relay (which adds the vendor's key on the server).
struct CloudCredential: Sendable, Equatable {
    enum Authorization: Sendable, Equatable {
        /// The user's own key (`xi-api-key`).
        case apiKey(String)
        /// The Captylo session token (`Authorization: Bearer`).
        case bearer(String)
    }

    var baseURL: URL
    var authorization: Authorization
    /// True for the relay: it needs the audio length header and has its own errors (402, 403).
    var isRelay: Bool

    /// The user's own key, straight to the vendor.
    static func ownKey(_ key: String, baseURL: URL = ElevenLabsSTT.apiBaseURL) -> CloudCredential {
        CloudCredential(baseURL: baseURL, authorization: .apiKey(key), isRelay: false)
    }

    /// The Pro session, through the relay.
    static func relay(token: String, baseURL: URL) -> CloudCredential {
        CloudCredential(baseURL: baseURL, authorization: .bearer(token), isRelay: true)
    }

    /// The key or token, trimmed; nil when blank (no route).
    var secret: String? {
        let raw: String
        switch authorization {
        case .apiKey(let key): raw = key
        case .bearer(let token): raw = token
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

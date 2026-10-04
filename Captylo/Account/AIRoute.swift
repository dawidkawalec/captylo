import Foundation

/// An AI request's destination: the client to build requests with (the vendor's or the relay's
/// base URL), the key it signs with (the user's own key or the Pro session token) and the model.
/// `model == nil` is the Pro relay: the server picks the model and ignores the one sent.
struct AIRoute: Sendable, Equatable {
    var client: OpenRouterClient
    var key: String
    var model: String?

    var isRelay: Bool { model == nil }
}

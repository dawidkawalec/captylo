import Foundation

/// The one routing rule for cloud requests: the user's own key first (straight to the vendor, the
/// chosen model honoured), else the Pro session (through the Captylo relay, the server picks the
/// model), else no route (the caller stays local or reports the missing key). Built once in
/// `AppState`; resolved per request, so adding or removing a key or signing in takes effect on
/// the next request without a restart.
///
/// On the dictation path the lookup is one Keychain read (cached after launch) plus, without an
/// own key, the account's in-memory Pro check and its cached token, all within one timeout.
struct CloudRouter: Sendable {
    let keyStore: KeyStore
    /// The account's session token when it is Pro, `.value(nil)` otherwise (`AccountStore.relayToken`);
    /// gets what is left of the timeout.
    let accountToken: @Sendable (Duration) async -> KeyStore.KeyLookup
    let relayBaseURL: URL
    let aiClient: OpenRouterClient
    let sttBaseURL: URL

    init(
        keyStore: KeyStore,
        accountToken: @escaping @Sendable (Duration) async -> KeyStore.KeyLookup,
        relayBaseURL: URL = AccountClient.resolveBaseURL(),
        aiClient: OpenRouterClient = OpenRouterClient(),
        sttBaseURL: URL = ElevenLabsSTT.apiBaseURL
    ) {
        self.keyStore = keyStore
        self.accountToken = accountToken
        self.relayBaseURL = relayBaseURL
        self.aiClient = aiClient
        self.sttBaseURL = sttBaseURL
    }

    /// The speech-to-text credential; `.value(nil)` = no route.
    func sttCredential(timeout: Duration) async -> KeyStore.Lookup<CloudCredential> {
        await resolve(KeyStore.Account.elevenLabs, timeout: timeout,
                      own: { CloudCredential.ownKey($0, baseURL: sttBaseURL) },
                      relay: { CloudCredential.relay(token: $0, baseURL: relayBaseURL) })
    }

    /// The AI route for `model` (used only with an own key); `.value(nil)` = no route.
    func aiRoute(timeout: Duration, model: String) async -> KeyStore.Lookup<AIRoute> {
        await resolve(KeyStore.Account.openRouter, timeout: timeout,
                      own: { AIRoute(client: aiClient, key: $0, model: model) },
                      relay: { AIRoute(client: OpenRouterClient(baseURL: relayBaseURL), key: $0, model: nil) })
    }

    private func resolve<Route: Sendable>(
        _ account: String,
        timeout: Duration,
        own: (String) -> Route,
        relay: (String) -> Route
    ) async -> KeyStore.Lookup<Route> {
        let clock = ContinuousClock()
        let start = clock.now
        switch await keyStore.load(account, timeout: timeout) {
        case .timedOut:
            return .timedOut
        case .value(let key):
            if let key = Self.nonBlank(key) {
                return .value(own(key))
            }
        }
        let remaining = max(.zero, timeout - (clock.now - start))
        switch await accountToken(remaining) {
        case .timedOut:
            return .timedOut
        case .value(let token):
            return .value(Self.nonBlank(token).map(relay))
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

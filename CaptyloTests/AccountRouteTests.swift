import Foundation
import Security
import Testing
import os
@testable import Captylo

/// `CloudRouter`: an own key first, then the Pro session (the relay), else no route; and the
/// account's relay token (`AccountStore.relayToken`).
struct AccountRouteTests {
    private static let relay = URL(string: "https://relay.example.test/v1")!
    private static let token = "test-session-token-not-a-real-one-000000000"

    private func router(
        keys: [String: String] = [:],
        token: @escaping @Sendable (Duration) async -> KeyStore.KeyLookup = { _ in .value(nil) },
        reader: KeyStore.Reader? = nil
    ) -> CloudRouter {
        let store = reader.map { KeyStore(service: "com.captylo.app.tests", seed: keys, reader: $0) } ?? KeyStore.inMemory(seed: keys)
        return CloudRouter(keyStore: store, accountToken: token, relayBaseURL: Self.relay)
    }

    // MARK: Speech to text

    @Test func ownCloudKeyWinsOverPro() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let router = router(keys: [KeyStore.Account.elevenLabs: " xi-own "]) { _ in
            calls.withLock { $0 += 1 }
            return .value(Self.token)
        }
        let route = await router.sttCredential(timeout: .seconds(1))
        #expect(route == .value(CloudCredential(baseURL: ElevenLabsSTT.apiBaseURL, authorization: .apiKey("xi-own"), isRelay: false)))
        #expect(calls.withLock { $0 } == 0, "the account is not asked while an own key exists")
    }

    @Test func proSessionGoesToTheRelayWithTheBearer() async {
        let router = router { _ in .value(Self.token) }
        let route = await router.sttCredential(timeout: .seconds(1))
        #expect(route == .value(CloudCredential(baseURL: Self.relay, authorization: .bearer(Self.token), isRelay: true)))
    }

    @Test func neitherKeyNorProIsNoRoute() async {
        #expect(await router().sttCredential(timeout: .seconds(1)) == .value(nil))
        let blankToken = router { _ in .value("  ") }
        #expect(await blankToken.sttCredential(timeout: .seconds(1)) == .value(nil))
        let blankKey = router(keys: [KeyStore.Account.elevenLabs: "   "])
        #expect(await blankKey.sttCredential(timeout: .seconds(1)) == .value(nil))
    }

    @Test func keychainTimeoutPropagates() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let blocked = router(token: { _ in .value(Self.token) }, reader: { _, _ in
            gate.wait()
            return KeyStore.ReadResult(value: nil, status: errSecItemNotFound)
        })
        #expect(await blocked.sttCredential(timeout: .milliseconds(50)) == .timedOut)

        let slowToken = router { _ in .timedOut }
        #expect(await slowToken.sttCredential(timeout: .seconds(1)) == .timedOut)
    }

    @Test func theTokenGetsWhatIsLeftOfTheTimeout() async {
        let budget = OSAllocatedUnfairLock<Duration?>(initialState: nil)
        let router = router { remaining in
            budget.withLock { $0 = remaining }
            return .value(nil)
        }
        _ = await router.sttCredential(timeout: .seconds(2))
        let remaining = budget.withLock { $0 }
        #expect(remaining != nil)
        #expect(remaining! <= .seconds(2))
        #expect(remaining! > .seconds(1))
    }

    // MARK: AI

    @Test func ownAIKeyKeepsTheChosenModel() async {
        let router = router(keys: [KeyStore.Account.openRouter: "sk-or-own"]) { _ in .value(Self.token) }
        let route = await router.aiRoute(timeout: .seconds(1), model: "openai/gpt-4.1-mini")
        #expect(route == .value(AIRoute(client: OpenRouterClient(), key: "sk-or-own", model: "openai/gpt-4.1-mini")))
        if case .value(let found?) = route {
            #expect(!found.isRelay)
        }
    }

    @Test func proAIRouteLetsTheServerPickTheModel() async throws {
        let router = router { _ in .value(Self.token) }
        let route = await router.aiRoute(timeout: .seconds(1), model: "openai/gpt-4.1-mini")
        guard case .value(let found?) = route else {
            Issue.record("expected a relay route, got \(route)")
            return
        }
        #expect(found.isRelay)
        #expect(found.model == nil)
        #expect(found.key == Self.token)
        #expect(found.client.baseURL == Self.relay)
        let request = found.client.chatRequest(model: Enhancer.relayModelPlaceholder, system: "s", transcript: "t", maxTokens: 10, key: found.key)
        #expect(request.url == URL(string: "https://relay.example.test/v1/chat/completions"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    @Test func noAIRouteWithoutKeyOrPro() async {
        #expect(await router().aiRoute(timeout: .seconds(1), model: "m") == .value(nil))
        let slow = router { _ in .timedOut }
        #expect(await slow.aiRoute(timeout: .seconds(1), model: "m") == .timedOut)
    }

    @Test func removingTheOwnKeyRoutesTheNextRequestThroughTheRelay() async throws {
        let store = KeyStore.inMemory(seed: [KeyStore.Account.openRouter: "sk-or-own"])
        let router = CloudRouter(keyStore: store, accountToken: { _ in .value(Self.token) }, relayBaseURL: Self.relay)
        guard case .value(let first?) = await router.aiRoute(timeout: .seconds(1), model: "m") else {
            Issue.record("expected the own key route")
            return
        }
        #expect(!first.isRelay)
        try store.delete(account: KeyStore.Account.openRouter)
        guard case .value(let second?) = await router.aiRoute(timeout: .seconds(1), model: "m") else {
            Issue.record("expected the relay route")
            return
        }
        #expect(second.isRelay)
    }

    // MARK: The Pro card in Modele

    @Test func proCardFollowsTheAccount() throws {
        let pro = AccountStore.State.signedIn(try AccountFixtures.proInfo())
        let free = AccountStore.State.signedIn(try AccountFixtures.freeInfo())
        #expect(ProStatusCard.kind(state: pro, isPro: true, isStale: false) == .pro)
        #expect(ProStatusCard.kind(state: pro, isPro: false, isStale: true) == .stale)
        #expect(ProStatusCard.kind(state: free, isPro: false, isStale: false) == .free)
        #expect(ProStatusCard.kind(state: .signedOut, isPro: false, isStale: false) == .signedOut)
        #expect(ProStatusCard.kind(state: .codeSent(email: "anna@example.com"), isPro: false, isStale: false) == .signedOut)
    }

    // MARK: The account's token

    @MainActor
    private func account(state: AccountStore.State?, cached: AccountInfo?, token: String?) throws -> AccountStore {
        let name = "account-route-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        if let cached {
            settings.accountCache = try AccountClient.encodeCache(cached)
            settings.accountRefreshedAt = Date()
        }
        return AccountStore(
            client: AccountClient(baseURL: Self.relay, session: StubURLProtocol.makeSession()),
            keyStore: .inMemory(seed: token.map { [KeyStore.Account.captyloAccount: $0] } ?? [:]),
            settings: settings,
            pinned: state
        )
    }

    @MainActor
    @Test func aProAccountHandsOutItsToken() async throws {
        let pro = try account(state: nil, cached: AccountFixtures.proInfo(), token: Self.token)
        #expect(await pro.relayToken(timeout: .seconds(1)) == .value(Self.token))
    }

    @MainActor
    @Test func aFreeOrPinnedAccountHasNoRelayToken() async throws {
        let free = try account(state: nil, cached: AccountFixtures.freeInfo(), token: Self.token)
        #expect(await free.relayToken(timeout: .seconds(1)) == .value(nil))
        let signedOut = try account(state: nil, cached: nil, token: Self.token)
        #expect(await signedOut.relayToken(timeout: .seconds(1)) == .value(nil))
        // The design preview and the test host pin a Pro account but never reach the relay.
        let pinned = try account(state: .signedIn(AccountFixtures.proInfo()), cached: nil, token: Self.token)
        #expect(pinned.isPro)
        #expect(await pinned.relayToken(timeout: .seconds(1)) == .value(nil))
    }
}

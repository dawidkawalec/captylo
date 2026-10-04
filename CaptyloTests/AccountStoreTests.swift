import Foundation
import Security
import Testing
import os
@testable import Captylo

@MainActor
struct AccountStoreTests {
    private static let token = "test-session-token-not-a-real-one-000000000"

    private func settings() -> AppSettings {
        let name = "account-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults)
    }

    private func store(
        base: URL,
        settings: AppSettings,
        keyStore: KeyStore = .inMemory(),
        pinned: AccountStore.State? = nil,
        now: Date = Date()
    ) -> AccountStore {
        AccountStore(
            client: AccountClient(baseURL: base, session: StubURLProtocol.makeSession()),
            keyStore: keyStore,
            settings: settings,
            pinned: pinned,
            now: { now },
            deepLinkDelays: [.zero, .zero]
        )
    }

    private func seedCache(_ settings: AppSettings, info: AccountInfo, refreshedAt: Date) throws {
        settings.accountCache = try AccountClient.encodeCache(info)
        settings.accountRefreshedAt = refreshedAt
    }

    // MARK: Sign in

    @Test func signInWithACode() async throws {
        let log = AccountRequestLog()
        let verify = try AccountFixtures.text("account-verify")
        let base = StubURLProtocol.register { request in
            log.append(request)
            switch request.url?.path() ?? "" {
            case "/api/v1/auth/code": return StubURLProtocol.Reply(status: 204)
            case "/api/v1/auth/verify": return .json(verify)
            default: return .json(#"{"error":"not_found"}"#, status: 404)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let keys = KeyStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let account = store(base: base, settings: s, keyStore: keys, now: now)
        #expect(account.state == .signedOut)

        await account.requestCode(email: "  Anna@Example.com ")
        #expect(account.state == .codeSent(email: "anna@example.com"))
        #expect(account.lastError == nil)
        #expect(account.isBusy == false)

        await account.verify(code: " 123456 ")
        guard case .signedIn(let info) = account.state else {
            Issue.record("not signed in: \(account.state)")
            return
        }
        #expect(info.email == "anna@example.com")
        #expect(info.plan == .free)
        #expect(account.isPro == false)
        #expect(keys.get(KeyStore.Account.captyloAccount) == Self.token)
        #expect(s.accountCache != nil)
        #expect(s.accountRefreshedAt == now)
        #expect(account.refreshedAt == now)
        #expect(log.paths == ["/api/v1/auth/code", "/api/v1/auth/verify"])
        let body = AccountFixtures.body(of: log.all[1])
        #expect(body["email"] as? String == "anna@example.com")
        #expect(body["code"] as? String == "123456")
    }

    @Test func aBadAddressNeverLeavesTheMac() async {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return StubURLProtocol.Reply(status: 204)
        }
        defer { StubURLProtocol.unregister(base) }
        let account = store(base: base, settings: settings())

        await account.requestCode(email: "anna")
        #expect(account.state == .signedOut)
        #expect(account.lastError == AccountError.invalidEmail.errorDescription)
        await account.requestCode(email: "anna @example.com")
        #expect(account.state == .signedOut)
        #expect(log.all.isEmpty)
    }

    @Test func aWrongCodeKeepsTheCodeStep() async throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            switch request.url?.path() ?? "" {
            case "/api/v1/auth/code": return StubURLProtocol.Reply(status: 204)
            default: return .json(#"{"error":"invalid_code"}"#, status: 400)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let keys = KeyStore.inMemory()
        let account = store(base: base, settings: settings(), keyStore: keys)

        await account.requestCode(email: "anna@example.com")
        await account.verify(code: "000000")
        #expect(account.state == .codeSent(email: "anna@example.com"))
        #expect(account.lastError == AccountError.invalidCode.errorDescription)
        #expect(keys.get(KeyStore.Account.captyloAccount) == nil)

        // Not six digits: refused locally, nothing sent.
        await account.verify(code: "12ab")
        #expect(account.lastError == AccountError.invalidCode.errorDescription)
        #expect(log.all.count == 2)

        account.cancelCode()
        #expect(account.state == .signedOut)
        #expect(account.lastError == nil)
    }

    @Test func aMailFailureSaysSo() async {
        let base = StubURLProtocol.register { _ in .json(#"{"error":"mail_failed"}"#, status: 502) }
        defer { StubURLProtocol.unregister(base) }
        let account = store(base: base, settings: settings())
        await account.requestCode(email: "anna@example.com")
        #expect(account.state == .signedOut)
        #expect(account.lastError == AccountError.mailFailed.errorDescription)
    }

    // MARK: Cache

    @Test func theCacheIsRestoredAtInitWithoutTheNetwork() throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .failure(.notConnectedToInternet)
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: now.addingTimeInterval(-3600))

        let account = store(base: base, settings: s, now: now)
        #expect(account.state == .signedIn(try AccountFixtures.proInfo()))
        #expect(account.info?.plan == .pro)
        #expect(account.isPro)
        #expect(account.isStale == false)
        #expect(log.all.isEmpty)
    }

    @Test func aCacheOlderThanSevenDaysIsNotPro() throws {
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: now.addingTimeInterval(-(7 * 24 * 3600 + 60)))
        let account = store(base: AccountClient.defaultBaseURL, settings: s, now: now)
        #expect(account.info?.plan == .pro)
        #expect(account.isPro == false)
        #expect(account.isStale)

        // Exactly seven days is still Pro.
        let edge = settings()
        try seedCache(edge, info: AccountFixtures.proInfo(), refreshedAt: now.addingTimeInterval(-7 * 24 * 3600))
        #expect(store(base: AccountClient.defaultBaseURL, settings: edge, now: now).isPro)
    }

    @Test func aBrokenCacheIsSignedOut() {
        let s = settings()
        s.accountCache = "{"
        s.accountRefreshedAt = Date()
        #expect(store(base: AccountClient.defaultBaseURL, settings: s).state == .signedOut)
    }

    // MARK: Refresh

    @Test func refreshUpdatesThePlanAndTheCache() async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json(pro)
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: now.addingTimeInterval(-86_400))
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]), now: now)
        #expect(account.isPro == false)

        await account.refresh()
        #expect(account.isPro)
        #expect(account.refreshedAt == now)
        #expect(s.accountRefreshedAt == now)
        #expect(try AccountClient.decodeCache(#require(s.accountCache)).plan == .pro)
        #expect(log.all.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    /// Back from the browser without the deep link: activation refreshes only after a billing page.
    @Test func comingBackAfterCheckoutRefreshesThePlan() async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            switch request.url?.path() ?? "" {
            case "/api/v1/billing/checkout": return .json(#"{"url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#)
            default: return .json(pro)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: now)
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]), now: now)

        await account.appDidBecomeActive()
        #expect(log.all.isEmpty)

        #expect(await account.checkoutURL(plan: .yearly) != nil)
        await account.appDidBecomeActive()
        #expect(log.paths == ["/api/v1/billing/checkout", "/api/v1/me"])
        #expect(account.isPro)
    }

    @Test func thePanelRefreshesOnlyAStalePlan() async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json(pro)
        }
        defer { StubURLProtocol.unregister(base) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let keys = KeyStore.inMemory(seed: [KeyStore.Account.captyloAccount: Self.token])

        let fresh = settings()
        try seedCache(fresh, info: AccountFixtures.freeInfo(), refreshedAt: now.addingTimeInterval(-60))
        await store(base: base, settings: fresh, keyStore: keys, now: now).refreshIfStale()
        #expect(log.all.isEmpty)

        let stale = settings()
        try seedCache(stale, info: AccountFixtures.freeInfo(), refreshedAt: now.addingTimeInterval(-AccountStore.staleAfter - 1))
        let account = store(base: base, settings: stale, keyStore: keys, now: now)
        await account.refreshIfStale()
        #expect(log.paths == ["/api/v1/me"])
        #expect(account.isPro)
    }

    @Test func aRevokedSessionSignsOutAtOnce() async throws {
        let base = StubURLProtocol.register { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: Date())
        let keys = KeyStore.inMemory(seed: [KeyStore.Account.captyloAccount: Self.token])
        let account = store(base: base, settings: s, keyStore: keys)
        #expect(account.isPro)

        await account.refresh()
        #expect(account.state == .signedOut)
        #expect(account.isPro == false)
        #expect(account.lastError == AccountError.unauthorized.errorDescription)
        #expect(keys.get(KeyStore.Account.captyloAccount) == nil)
        #expect(s.accountCache == nil)
        #expect(s.accountRefreshedAt == nil)
    }

    @Test func offlineRefreshKeepsTheCachedPro() async throws {
        let base = StubURLProtocol.register { _ in .failure(.notConnectedToInternet) }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let refreshed = now.addingTimeInterval(-2 * 86_400)
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: refreshed)
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]), now: now)

        await account.refresh()
        #expect(account.isPro)
        #expect(account.refreshedAt == refreshed)
        // A background refresh never shows an error; the stale line covers a long outage.
        #expect(account.lastError == nil)
    }

    @Test func aCacheWithoutATokenSignsOut() async throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json("{}")
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: Date())
        let account = store(base: base, settings: s, keyStore: .inMemory())

        await account.refresh()
        #expect(account.state == .signedOut)
        #expect(s.accountCache == nil)
        #expect(log.all.isEmpty)
    }

    /// A denied ACL prompt or a locked keychain is not a missing token: the account, the cache
    /// and the stored token stay, and the next readable refresh goes on as usual.
    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed])
    func anUnreadableTokenKeepsTheAccount(status: OSStatus) async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json(pro)
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let refreshed = now.addingTimeInterval(-86_400)
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: refreshed)
        let readable = OSAllocatedUnfairLock(initialState: false)
        let token = Self.token
        let keys = KeyStore(service: "com.captylo.app.tests") { _, _ in
            readable.withLock { $0 }
                ? KeyStore.ReadResult(value: token, status: errSecSuccess)
                : KeyStore.ReadResult(value: nil, status: status)
        }
        let account = store(base: base, settings: s, keyStore: keys, now: now)
        let before = account.state

        await account.refresh()
        #expect(account.state == before)
        #expect(account.isPro)
        #expect(account.refreshedAt == refreshed)
        #expect(account.lastError == nil)
        #expect(s.accountCache != nil)
        #expect(s.accountRefreshedAt == refreshed)
        #expect(log.all.isEmpty)

        // A billing link says the session could not be read and can be retried.
        #expect(await account.checkoutURL(plan: .yearly) == nil)
        #expect(account.state == before)
        #expect(account.lastError == AccountError.keychainUnavailable.errorDescription)
        #expect(s.accountCache != nil)
        #expect(log.all.isEmpty)

        // The token was never forgotten: once readable, the refresh uses it.
        readable.withLock { $0 = true }
        await account.refresh()
        #expect(account.refreshedAt == now)
        #expect(log.all.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    // MARK: Sign out and billing

    @Test func signOutRevokesAndForgets() async throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return StubURLProtocol.Reply(status: 204)
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: Date())
        let keys = KeyStore.inMemory(seed: [KeyStore.Account.captyloAccount: Self.token])
        let account = store(base: base, settings: s, keyStore: keys)

        await account.signOut()
        #expect(account.state == .signedOut)
        #expect(keys.get(KeyStore.Account.captyloAccount) == nil)
        #expect(s.accountCache == nil)
        #expect(log.paths == ["/api/v1/auth/logout"])
        #expect(log.all.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    @Test func signOutWorksOffline() async throws {
        let base = StubURLProtocol.register { _ in .failure(.notConnectedToInternet) }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.proInfo(), refreshedAt: Date())
        let keys = KeyStore.inMemory(seed: [KeyStore.Account.captyloAccount: Self.token])
        let account = store(base: base, settings: s, keyStore: keys)

        await account.signOut()
        #expect(account.state == .signedOut)
        #expect(account.lastError == nil)
        #expect(keys.get(KeyStore.Account.captyloAccount) == nil)
    }

    @Test func checkoutAndPortalURLs() async throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            switch request.url?.path() ?? "" {
            case "/api/v1/billing/checkout": return .json(#"{"url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#)
            default: return .json(#"{"error":"no_customer"}"#, status: 404)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: Date())
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]))

        let checkout = await account.checkoutURL(plan: .yearly)
        #expect(checkout?.absoluteString == "https://checkout.stripe.com/c/pay/cs_test_1")
        #expect(AccountFixtures.body(of: log.all[0])["plan"] as? String == "yearly")
        #expect(account.isBusy == false)

        let portal = await account.portalURL()
        #expect(portal == nil)
        #expect(account.lastError == AccountError.noCustomer.errorDescription)
    }

    @Test func alreadyProRefreshesThePlan() async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let base = StubURLProtocol.register { request in
            switch request.url?.path() ?? "" {
            case "/api/v1/billing/checkout": return .json(#"{"error":"already_pro"}"#, status: 409)
            default: return .json(pro)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: Date())
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]))

        #expect(await account.checkoutURL(plan: .monthly) == nil)
        #expect(account.lastError == AccountError.alreadyPro.errorDescription)
        #expect(account.isPro)
    }

    @Test func paymentPendingRefreshesThePlanAndSaysWhy() async throws {
        let unpaidJSON = try AccountFixtures.text("account-me-free")
            .replacingOccurrences(of: #""status": null"#, with: #""status": "past_due""#)
        #expect(unpaidJSON.contains("past_due"))
        let base = StubURLProtocol.register { request in
            switch request.url?.path() ?? "" {
            case "/api/v1/billing/checkout": return .json(#"{"error":"payment_pending"}"#, status: 409)
            default: return .json(unpaidJSON)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: Date())
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]))

        #expect(await account.checkoutURL(plan: .yearly) == nil)
        #expect(account.lastError == AccountError.paymentPending.errorDescription)
        #expect(account.info?.needsPaymentUpdate == true)
    }

    // MARK: Pinned and deep links

    @Test func aPinnedStoreNeverTouchesTheNetwork() async throws {
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json("{}")
        }
        defer { StubURLProtocol.unregister(base) }
        let pro = try AccountFixtures.proInfo()
        let account = store(base: base, settings: settings(), pinned: .signedIn(pro))
        #expect(account.isPro)

        await account.refresh()
        await account.requestCode(email: "anna@example.com")
        await account.signOut()
        #expect(await account.checkoutURL(plan: .yearly) == nil)
        #expect(account.handleDeepLink(URL(string: "captylo://pro/done")!))
        await account.deepLinkTask?.value
        #expect(account.state == .signedIn(pro))
        #expect(log.all.isEmpty)
    }

    @Test func aDeepLinkRefreshesNowAndAgain() async throws {
        let pro = try AccountFixtures.text("account-me-pro")
        let log = AccountRequestLog()
        let base = StubURLProtocol.register { request in
            log.append(request)
            return .json(pro)
        }
        defer { StubURLProtocol.unregister(base) }
        let s = settings()
        try seedCache(s, info: AccountFixtures.freeInfo(), refreshedAt: Date())
        let account = store(base: base, settings: s, keyStore: .inMemory(seed: [KeyStore.Account.captyloAccount: Self.token]))

        #expect(account.handleDeepLink(URL(string: "captylo://other")!) == false)
        #expect(account.handleDeepLink(URL(string: "captylo://pro/done")!))
        await account.deepLinkTask?.value
        #expect(account.isPro)
        #expect(log.paths == ["/api/v1/me", "/api/v1/me"])
    }
}

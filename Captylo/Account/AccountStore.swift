import Foundation
import Observation

/// The Captylo account in the app: sign-in with an e-mail code, the session token in the login
/// Keychain (`KeyStore.Account.captyloAccount`), the last `/v1/me` cached in defaults so Pro is
/// known at launch before the network answers, and a refresh at launch and every 6 hours.
///
/// Offline Pro: a cached Pro plan stays Pro for 7 days after the last successful refresh, then
/// reads as Free until a refresh succeeds. A revoked session (401) signs out at once.
/// A `pinned` store (design preview, test host) never reads the Keychain or the network.
@MainActor
@Observable
final class AccountStore {
    enum State: Equatable, Sendable {
        case signedOut
        case codeSent(email: String)
        case signedIn(AccountInfo)
    }

    nonisolated static let cacheMaxAge: TimeInterval = 7 * 24 * 3600
    nonisolated static let refreshInterval: Duration = .seconds(6 * 3600)
    /// After a deep link: refresh now, then 3 s and 10 s later (the webhook may lag the redirect).
    nonisolated static let deepLinkDelays: [Duration] = [.zero, .seconds(3), .seconds(7)]
    /// Off the hot path: a longer Keychain wait than dictation, still bounded by an ACL prompt.
    nonisolated static let keychainTimeout: Duration = .seconds(10)
    /// Coming back to the app this soon after a Checkout or Portal page opened refreshes the plan:
    /// the user may close the tab without the "Otwórz Captylo" deep link.
    nonisolated static let billingReturnWindow: TimeInterval = 30 * 60
    /// The account panel refreshes a plan confirmed longer ago than this.
    nonisolated static let staleAfter: TimeInterval = 5 * 60

    private(set) var state: State
    /// A user action (send, verify, a billing link) is running.
    private(set) var isBusy = false
    /// The last user-facing error (Polish), nil after a success.
    private(set) var lastError: String?
    /// When the shown plan was last confirmed by the server.
    private(set) var refreshedAt: Date?

    @ObservationIgnored private let client: AccountClient
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let pinned: State?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let delays: [Duration]
    /// Bumped on every sign-in and sign-out, so an answer that arrives after either is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// When a Checkout or Portal page was last opened from the app.
    @ObservationIgnored private var billingOpenedAt: Date?
    /// The refreshes a deep link started (tests await it).
    @ObservationIgnored private(set) var deepLinkTask: Task<Void, Never>?

    init(
        client: AccountClient,
        keyStore: KeyStore,
        settings: AppSettings,
        pinned: State? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        deepLinkDelays: [Duration] = AccountStore.deepLinkDelays
    ) {
        self.client = client
        self.keyStore = keyStore
        self.settings = settings
        self.pinned = pinned
        self.now = now
        delays = deepLinkDelays
        if let pinned {
            state = pinned
            refreshedAt = now()
        } else if let cached = AccountClient.decodeCacheOrNil(settings.accountCache) {
            // The token is checked by the first refresh (no Keychain read on the main thread).
            state = .signedIn(cached)
            refreshedAt = settings.accountRefreshedAt
        } else {
            state = .signedOut
            refreshedAt = nil
        }
    }

    /// The signed-in account, nil otherwise.
    var info: AccountInfo? {
        if case .signedIn(let info) = state {
            return info
        }
        return nil
    }

    /// Pro from a signed-in account whose plan the server confirmed in the last 7 days; a trial
    /// stops at its end even without a refresh.
    var isPro: Bool {
        guard let info, info.isPro(at: now()) else { return false }
        if pinned != nil {
            return true
        }
        return isFresh
    }

    /// Pro from the reverse trial right now.
    var isTrial: Bool {
        guard let info else { return false }
        return info.isTrial && isPro
    }

    /// A cached Pro plan that could not be confirmed for over 7 days (offline): shown as a
    /// warning, Pro returns after a successful refresh.
    var isStale: Bool {
        guard let info, info.isPro(at: now()), pinned == nil else { return false }
        return !isFresh
    }

    /// The session token for the Pro relay (`CloudRouter`): only while `isPro`. A pinned store
    /// (design preview, test host) never hands one out, so neither ever reaches the relay.
    func relayToken(timeout: Duration) async -> KeyStore.KeyLookup {
        guard pinned == nil, isPro else { return .value(nil) }
        return await keyStore.load(KeyStore.Account.captyloAccount, timeout: timeout)
    }

    private var isFresh: Bool {
        guard let refreshedAt else { return false }
        return now().timeIntervalSince(refreshedAt) <= Self.cacheMaxAge
    }

    // MARK: Sign in

    /// Sends a code to `email` (trimmed, lowercased); a malformed address never leaves the Mac.
    func requestCode(email: String) async {
        guard pinned == nil, !isBusy else { return }
        let address = Self.normalizedEmail(email)
        guard Self.looksLikeEmail(address) else {
            lastError = AccountError.invalidEmail.errorDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.requestCode(email: address)
            state = .codeSent(email: address)
            lastError = nil
            Log.account.info("Login code requested")
        } catch {
            lastError = Self.message(error)
        }
    }

    /// Checks the six digits for the address the code went to; on success stores the token
    /// and the account.
    func verify(code: String) async {
        guard pinned == nil, !isBusy, case .codeSent(let email) = state else { return }
        let digits = code.filter { !$0.isWhitespace }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            lastError = AccountError.invalidCode.errorDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let answer = try await client.verify(email: email, code: digits, device: AccountClient.deviceName())
            try keyStore.set(answer.token, account: KeyStore.Account.captyloAccount)
            generation += 1
            apply(answer.me)
            lastError = nil
            Log.account.info("Signed in, plan \(answer.me.plan.rawValue, privacy: .public)")
        } catch {
            lastError = Self.message(error)
        }
    }

    /// "Wróć": back to the address field.
    func cancelCode() {
        guard pinned == nil, case .codeSent = state else { return }
        state = .signedOut
        lastError = nil
    }

    // MARK: Refresh and sign out

    /// `GET /v1/me`. 401 signs out at once; other failures keep the cached plan quietly.
    /// Only a token that is really gone signs out; an unreadable one (denied ACL prompt, locked
    /// keychain) keeps the account like a timeout does, and the next refresh tries again.
    func refresh() async {
        guard pinned == nil else { return }
        let started = generation
        switch await keyStore.lookup(KeyStore.Account.captyloAccount, timeout: Self.keychainTimeout) {
        case .timedOut:
            Log.account.error("Account refresh: Keychain read did not finish in time")
        case .unreadable(let status):
            Log.account.error("Account refresh: Keychain read failed (\(status, privacy: .public)), account kept")
        case .absent:
            // A cache without a token (removed by hand): nothing to refresh.
            if case .signedIn = state, started == generation {
                forget()
            }
        case .found(let token):
            do {
                let info = try await client.me(token: token)
                guard started == generation else { return }
                apply(info)
            } catch AccountError.unauthorized {
                guard started == generation else { return }
                forget()
                lastError = AccountError.unauthorized.errorDescription
                Log.account.notice("Session revoked, signed out")
            } catch {
                // Offline or the server is down: the cache keeps Pro for up to 7 days.
            }
        }
    }

    /// "Wyloguj": forgets the token and the cache at once, then revokes the session (best effort).
    func signOut() async {
        guard pinned == nil else { return }
        // The user asked to sign out: an unreadable token still signs out, only the revoke is skipped.
        let token: String?
        if case .found(let stored) = await keyStore.lookup(KeyStore.Account.captyloAccount, timeout: Self.keychainTimeout) {
            token = stored
        } else {
            token = nil
        }
        forget()
        lastError = nil
        Log.account.info("Signed out")
        if let token {
            try? await client.logout(token: token)
        }
    }

    // MARK: Billing

    /// The Checkout page for "Przejdź na Pro"; nil (and `lastError`) when it cannot be opened.
    func checkoutURL(plan: BillingPlan) async -> URL? {
        await billingURL { client, token in try await client.checkoutURL(token: token, plan: plan) }
    }

    /// The subscription Portal for "Zarządzaj subskrypcją".
    func portalURL() async -> URL? {
        await billingURL { client, token in try await client.portalURL(token: token) }
    }

    private func billingURL(_ call: @Sendable (AccountClient, String) async throws -> URL) async -> URL? {
        guard pinned == nil, !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        guard let token = await sessionToken() else { return nil }
        do {
            let url = try await call(client, token)
            lastError = nil
            billingOpenedAt = now()
            return url
        } catch let error as AccountError where error == .alreadyPro || error == .paymentPending {
            // The cached plan is behind the server's: refresh so the card shows the right buttons.
            lastError = error.errorDescription
            await refresh()
        } catch AccountError.unauthorized {
            forget()
            lastError = AccountError.unauthorized.errorDescription
        } catch {
            lastError = Self.message(error)
        }
        return nil
    }

    /// The stored token. A token that is really gone signs out and asks to sign in again; one
    /// that cannot be read right now keeps the account and shows a retryable error.
    private func sessionToken() async -> String? {
        switch await keyStore.lookup(KeyStore.Account.captyloAccount, timeout: Self.keychainTimeout) {
        case .found(let token):
            return token
        case .absent:
            forget()
            lastError = AccountError.unauthorized.errorDescription
            return nil
        case .unreadable(let status):
            Log.account.error("Account token: Keychain read failed (\(status, privacy: .public)), account kept")
            lastError = AccountError.keychainUnavailable.errorDescription
            return nil
        case .timedOut:
            Log.account.error("Account token: Keychain read did not finish in time")
            lastError = AccountError.keychainUnavailable.errorDescription
            return nil
        }
    }

    // MARK: Launch and deep links

    /// Refreshes at launch and every 6 hours. Only from `AppState.startServices()`.
    func start() {
        guard pinned == nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: AccountStore.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// The app came to the front. Within 30 minutes of opening a Checkout or Portal page the plan
    /// may have changed in the browser, so it is refreshed; otherwise nothing happens.
    func appDidBecomeActive() async {
        guard pinned == nil, let opened = billingOpenedAt,
              now().timeIntervalSince(opened) <= Self.billingReturnWindow else { return }
        await refresh()
    }

    /// The account panel appeared: a signed-in plan confirmed more than 5 minutes ago is refreshed.
    func refreshIfStale() async {
        guard pinned == nil, case .signedIn = state else { return }
        if let refreshedAt, now().timeIntervalSince(refreshedAt) < Self.staleAfter { return }
        await refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        deepLinkTask?.cancel()
        deepLinkTask = nil
    }

    /// `captylo://pro/done` and `captylo://account/refresh`: refresh now, then again after 3 s
    /// and 10 s (the webhook may lag the redirect). False for any other URL.
    func handleDeepLink(_ url: URL) -> Bool {
        guard let kind = Self.deepLinkKind(url) else { return false }
        Log.account.info("Deep link \(String(describing: kind), privacy: .public)")
        guard pinned == nil else { return true }
        deepLinkTask?.cancel()
        let delays = self.delays
        deepLinkTask = Task { [weak self] in
            for delay in delays {
                if delay > .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
                await self?.refresh()
            }
        }
        return true
    }

    /// The deep link `url` is, or nil when it is not one of ours.
    nonisolated static func deepLinkKind(_ url: URL) -> DeepLinkKind? {
        guard url.scheme?.lowercased() == "captylo", let host = url.host()?.lowercased() else { return nil }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch (host, path) {
        case ("pro", "done"): return .proDone
        case ("account", "refresh"): return .refresh
        default: return nil
        }
    }

    // MARK: Helpers

    private func apply(_ info: AccountInfo) {
        let at = now()
        state = .signedIn(info)
        refreshedAt = at
        settings.accountCache = try? AccountClient.encodeCache(info)
        settings.accountRefreshedAt = at
    }

    /// Signs out locally. The Keychain item goes on the Keychain queue, so an ACL prompt on the
    /// delete never blocks the main actor.
    private func forget() {
        keyStore.removeInBackground(account: KeyStore.Account.captyloAccount)
        generation += 1
        state = .signedOut
        refreshedAt = nil
        settings.accountCache = nil
        settings.accountRefreshedAt = nil
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription {
            return text
        }
        return AccountError.serverUnavailable.errorDescription ?? ""
    }

    nonisolated static func normalizedEmail(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One "@", something before it, a dot inside the domain, no spaces, at most 254 characters.
    nonisolated static func looksLikeEmail(_ text: String) -> Bool {
        guard text.count <= 254, !text.contains(where: { $0.isWhitespace }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex, domain.index(after: dot) != domain.endIndex else {
            return false
        }
        return true
    }
}

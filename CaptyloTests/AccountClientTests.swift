import Foundation
import Testing
@testable import Captylo

struct AccountClientTests {
    // MARK: Base URL

    @Test func defaultBaseURLIsTheCaptyloAPI() {
        #expect(AccountClient.resolveBaseURL(environment: [:]).absoluteString == "https://api.captylo.com/v1")
        #expect(AccountClient.defaultBaseURL.absoluteString == "https://api.captylo.com/v1")
    }

    @Test func environmentOverridesTheBaseURL() {
        let local = AccountClient.resolveBaseURL(environment: ["CAPTYLO_API_BASE": "http://127.0.0.1:8787/v1/"])
        #expect(local.absoluteString == "http://127.0.0.1:8787/v1")
        // Anything that is not an http(s) URL with a host is ignored.
        #expect(AccountClient.resolveBaseURL(environment: ["CAPTYLO_API_BASE": "not a url"]) == AccountClient.defaultBaseURL)
        #expect(AccountClient.resolveBaseURL(environment: ["CAPTYLO_API_BASE": "file:///tmp/x"]) == AccountClient.defaultBaseURL)
        #expect(AccountClient.resolveBaseURL(environment: ["CAPTYLO_API_BASE": "  "]) == AccountClient.defaultBaseURL)
    }

    // MARK: Requests

    @Test func postRequestCarriesJSONAndNoAuthorizationWithoutAToken() throws {
        let request = try AccountClient.makeRequest(
            baseURL: AccountClient.defaultBaseURL,
            path: "auth/code",
            method: "POST",
            token: nil,
            json: ["email": "anna@example.com"]
        )
        #expect(request.url?.absoluteString == "https://api.captylo.com/v1/auth/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(AccountFixtures.body(of: request)["email"] as? String == "anna@example.com")
    }

    @Test func getRequestWithATokenHasABearerAndNoBody() throws {
        let request = try AccountClient.makeRequest(
            baseURL: AccountClient.defaultBaseURL,
            path: "me",
            method: "GET",
            token: "tok-123",
            json: nil
        )
        #expect(request.url?.absoluteString == "https://api.captylo.com/v1/me")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)
    }

    // MARK: Parsers

    @Test func parsesTheProAccount() throws {
        let info = try AccountFixtures.proInfo()
        #expect(info.email == "anna@example.com")
        #expect(info.plan == .pro)
        #expect(info.isPro)
        #expect(info.status == "active")
        // The server writes `toISOString()`, with milliseconds.
        #expect(info.periodEnd == (try AccountFixtures.date("2026-11-03T11:00:00Z")))
        #expect(info.cancelAtPeriodEnd == false)
        #expect(info.usage == AccountUsage(month: "2026-10", audioSeconds: 10800, audioSecondsLimit: 72000, aiTokens: 360000, aiTokensLimit: 3000000))
    }

    @Test func parsesTheFreeAccount() throws {
        let info = try AccountFixtures.freeInfo()
        #expect(info.plan == .free)
        #expect(info.isPro == false)
        #expect(info.status == nil)
        #expect(info.periodEnd == nil)
    }

    @Test func parsesTheVerifyAnswer() throws {
        let answer = try AccountClient.parseVerify(AccountFixtures.data("account-verify"))
        #expect(answer.token == "test-session-token-not-a-real-one-000000000")
        #expect(answer.me.plan == .free)
        #expect(answer.me.email == "anna@example.com")
    }

    @Test func anUnknownPlanOrABrokenBodyIsAServerError() {
        let weird = Data(#"{"email":"a@b.pl","plan":"team","status":null,"periodEnd":null,"cancelAtPeriodEnd":false,"usage":{"month":"2026-10","audioSeconds":0,"audioSecondsLimit":1,"aiTokens":0,"aiTokensLimit":1}}"#.utf8)
        #expect(throws: AccountError.serverUnavailable) { try AccountClient.parseMe(weird) }
        #expect(throws: AccountError.serverUnavailable) { try AccountClient.parseMe(Data("<html>".utf8)) }
        #expect(throws: AccountError.serverUnavailable) { try AccountClient.parseURL(Data(#"{"url":""}"#.utf8)) }
    }

    @Test func cachedInfoRoundTrips() throws {
        let info = try AccountFixtures.proInfo()
        let text = try AccountClient.encodeCache(info)
        #expect(try AccountClient.decodeCache(text) == info)
        #expect(AccountClient.decodeCacheOrNil("{") == nil)
    }

    // MARK: Status mapping

    @Test func mapsStatusesToAccountErrors() throws {
        func body(_ text: String) -> Data { Data(text.utf8) }
        #expect(AccountClient.mapStatus(200, body: Data()) == nil)
        #expect(AccountClient.mapStatus(204, body: Data()) == nil)
        #expect(AccountClient.mapStatus(400, body: body(#"{"error":"invalid_code"}"#)) == .invalidCode)
        #expect(AccountClient.mapStatus(400, body: body(#"{"error":"bad_request"}"#)) == .invalidEmail)
        #expect(AccountClient.mapStatus(401, body: body(#"{"error":"unauthorized"}"#)) == .unauthorized)
        #expect(AccountClient.mapStatus(402, body: body(#"{"error":"quota_exceeded","resetsAt":"2026-11-01T00:00:00.000Z"}"#))
            == .quotaExceeded(resetsAt: try AccountFixtures.date("2026-11-01T00:00:00Z")))
        #expect(AccountClient.mapStatus(402, body: body(#"{"error":"quota_exceeded"}"#)) == .quotaExceeded(resetsAt: nil))
        #expect(AccountClient.mapStatus(404, body: body(#"{"error":"no_customer"}"#)) == .noCustomer)
        #expect(AccountClient.mapStatus(404, body: body(#"{"error":"not_found"}"#)) == .serverUnavailable)
        #expect(AccountClient.mapStatus(409, body: body(#"{"error":"already_pro"}"#)) == .alreadyPro)
        #expect(AccountClient.mapStatus(409, body: body(#"{"error":"payment_pending"}"#)) == .paymentPending)
        #expect(AccountClient.mapStatus(502, body: body(#"{"error":"mail_failed"}"#)) == .mailFailed)
        #expect(AccountClient.mapStatus(502, body: body(#"{"error":"billing_unavailable"}"#)) == .serverUnavailable)
        #expect(AccountClient.mapStatus(500, body: Data()) == .serverUnavailable)
        #expect(AccountClient.mapStatus(429, body: body(#"{"error":"rate_limited"}"#)) == .serverUnavailable)
    }

    @Test func aFailedPaymentAsksForANewCard() throws {
        var info = try AccountFixtures.freeInfo()
        #expect(info.needsPaymentUpdate == false)
        for status in ["past_due", "unpaid"] {
            info.status = status
            #expect(info.needsPaymentUpdate)
        }
        for status in ["active", "trialing", "canceled", "incomplete"] {
            info.status = status
            #expect(info.needsPaymentUpdate == false)
        }
    }

    @Test func mapsTransportErrors() {
        #expect(AccountClient.mapTransport(URLError(.notConnectedToInternet)) == .offline)
        #expect(AccountClient.mapTransport(URLError(.networkConnectionLost)) == .offline)
        #expect(AccountClient.mapTransport(URLError(.timedOut)) == .serverUnavailable)
        #expect(AccountClient.mapTransport(URLError(.cannotConnectToHost)) == .serverUnavailable)
        #expect(AccountClient.mapTransport(AccountError.invalidCode) == .invalidCode)
    }

    @Test func errorTextsArePolishAndNameNoVendor() {
        let all: [AccountError] = [.invalidEmail, .invalidCode, .unauthorized, .alreadyPro, .paymentPending, .noCustomer, .mailFailed, .offline, .serverUnavailable, .keychainUnavailable, .quotaExceeded(resetsAt: nil)]
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            for vendor in ["ElevenLabs", "OpenRouter", "Scribe", "Resend"] {
                #expect(!text.contains(vendor))
            }
        }
        #expect(AccountError.invalidCode.errorDescription == String(localized: "Ten kod nie pasuje albo wygasł."))
    }

    // MARK: Calls over a stubbed session

    @Test func callsSendTheRightRequests() async throws {
        let seen = AccountRequestLog()
        let me = try AccountFixtures.text("account-me-pro")
        let verify = try AccountFixtures.text("account-verify")
        let base = StubURLProtocol.register { request in
            seen.append(request)
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("POST", "/api/v1/auth/code"): return StubURLProtocol.Reply(status: 204)
            case ("POST", "/api/v1/auth/verify"): return .json(verify)
            case ("GET", "/api/v1/me"): return .json(me)
            case ("POST", "/api/v1/auth/logout"): return StubURLProtocol.Reply(status: 204)
            case ("POST", "/api/v1/billing/checkout"): return .json(#"{"url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#)
            case ("POST", "/api/v1/billing/portal"): return .json(#"{"url":"https://billing.stripe.com/p/session/test_1"}"#)
            default: return .json(#"{"error":"not_found"}"#, status: 404)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let client = AccountClient(baseURL: base, session: StubURLProtocol.makeSession())

        try await client.requestCode(email: "anna@example.com")
        let signedIn = try await client.verify(email: "anna@example.com", code: "123456", device: "Mac14,2")
        #expect(signedIn.token == "test-session-token-not-a-real-one-000000000")
        let info = try await client.me(token: "tok")
        #expect(info.plan == .pro)
        let checkout = try await client.checkoutURL(token: "tok", plan: .monthly)
        #expect(checkout.absoluteString == "https://checkout.stripe.com/c/pay/cs_test_1")
        let portal = try await client.portalURL(token: "tok")
        #expect(portal.host() == "billing.stripe.com")
        try await client.logout(token: "tok")

        let requests = seen.all
        #expect(requests.count == 6)
        #expect(AccountFixtures.body(of: requests[0])["email"] as? String == "anna@example.com")
        let verifyBody = AccountFixtures.body(of: requests[1])
        #expect(verifyBody["code"] as? String == "123456")
        #expect(verifyBody["device"] as? String == "Mac14,2")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(AccountFixtures.body(of: requests[3])["plan"] as? String == "monthly")
        // Stripe's return pages follow the UI language (/pl/ under Polish, server since 1.0.13).
        #expect(AccountFixtures.body(of: requests[3])["lang"] as? String == AppLanguage.runningCode)
        #expect(AccountFixtures.body(of: requests[4])["lang"] as? String == AppLanguage.runningCode)
        #expect(requests[5].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func errorsComeBackAsAccountErrors() async throws {
        let base = StubURLProtocol.register { request in
            switch request.url?.path() ?? "" {
            case "/api/v1/me": return .json(#"{"error":"unauthorized"}"#, status: 401)
            case "/api/v1/auth/verify": return .json(#"{"error":"invalid_code"}"#, status: 400)
            default: return .failure(.notConnectedToInternet)
            }
        }
        defer { StubURLProtocol.unregister(base) }
        let client = AccountClient(baseURL: base, session: StubURLProtocol.makeSession())

        await #expect(throws: AccountError.unauthorized) { _ = try await client.me(token: "old") }
        await #expect(throws: AccountError.invalidCode) { _ = try await client.verify(email: "a@b.pl", code: "000000", device: "Mac") }
        await #expect(throws: AccountError.offline) { try await client.requestCode(email: "a@b.pl") }
    }

    @Test func deviceNameIsTheModelNotThePersonalComputerName() {
        let name = AccountClient.deviceName()
        #expect(!name.isEmpty)
        #expect(name.count <= 64)
    }
}

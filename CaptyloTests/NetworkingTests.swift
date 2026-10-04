import Foundation
import Security
import Testing
import os
@testable import Captylo

struct NetworkingTests {
    // MARK: Sessions

    @Test func llmSessionFailsFastWithoutCache() {
        let configuration = HTTP.llmSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!configuration.waitsForConnectivity)
        // Above the longest AI mode deadline (20 s): the Swift deadline race is the real limit.
        #expect(configuration.timeoutIntervalForRequest > AIMode.deadlineRange.upperBound)
        #expect(configuration.timeoutIntervalForResource > AIMode.deadlineRange.upperBound)
        #expect(configuration.httpMaximumConnectionsPerHost == 4)
    }

    @Test func uploadSessionHasLongTimeouts() {
        let configuration = HTTP.uploadSession.configuration
        #expect(configuration.timeoutIntervalForRequest == 60)
        // The resource cap must stay above the per-take deadline of a long file (brief 5.2).
        #expect(configuration.timeoutIntervalForResource >= ElevenLabsSTT.timeout(forAudioSeconds: 2 * 3600))
        let retry = HTTP.makeEphemeral().configuration
        #expect(retry.urlCache == nil)
        #expect(retry.timeoutIntervalForResource == configuration.timeoutIntervalForResource)
    }

    @Test func shortBodyIsSingleLineAndCapped() {
        #expect(HTTP.shortBody(Data("ab\ncd\r\nef".utf8)) == "ab cd ef")
        let long = String(repeating: "x", count: 500)
        let short = HTTP.shortBody(Data(long.utf8))
        #expect(short.count == 200)
        #expect(short.hasSuffix("..."))
    }

    // MARK: Multipart

    @Test func multipartUsesCRLFAndClosesOnce() throws {
        var form = Multipart()
        form.addField(name: "model_id", value: "scribe_v2")
        form.addFile(name: "file", fileName: "a.wav", contentType: "audio/wav", data: Data([0x52, 0x49, 0x46, 0x46]))
        let body = form.body
        let text = String(decoding: body, as: UTF8.self)
        let boundary = form.boundary

        #expect(boundary.hasPrefix("Boundary-"))
        #expect(form.contentTypeHeader == "multipart/form-data; boundary=\(boundary)")
        let expected = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"model_id\"\r\n\r\n"
            + "scribe_v2\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
            + "RIFF\r\n"
            + "--\(boundary)--\r\n"
        #expect(text == expected)
        #expect(text.components(separatedBy: "--\(boundary)--").count == 2)
        #expect(!text.contains("\n\n"))
        // Reading `body` twice must not append a second closing boundary.
        #expect(form.body == body)
    }

    // MARK: Prewarmer

    @Test func prewarmerFiresAtMostOncePerInterval() async throws {
        let counter = Counter()
        let baseURL = StubURLProtocol.register { _ in
            counter.increment()
            return .json("{}")
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let session = StubURLProtocol.makeSession()
        let prewarmer = Prewarmer()
        let request = URLRequest(url: baseURL.appending(path: "auth/key"))

        await prewarmer.fire(request, using: session, minInterval: .seconds(20))
        await prewarmer.fire(request, using: session, minInterval: .seconds(20))
        await prewarmer.fire(request, using: session, minInterval: .seconds(20))
        try await waitUntil { counter.value >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.value == 1)

        await prewarmer.fire(request, using: session, minInterval: .zero)
        try await waitUntil { counter.value >= 2 }
        #expect(counter.value == 2)
    }

    // MARK: KeyStore

    @Test func keyStoreRoundTripInLoginKeychain() throws {
        let service = "com.captylo.app.tests"
        let account = "test-\(UUID().uuidString)"
        let store = KeyStore(service: service)
        do {
            try store.set("first-value", account: account)
        } catch {
            // Headless CI or a locked keychain: record and skip instead of failing the suite.
            withKnownIssue("Keychain unavailable in this environment", isIntermittent: true) {
                throw error
            }
            return
        }
        defer { try? store.delete(account: account) }

        #expect(store.get(account) == "first-value")
        // A fresh instance has an empty cache, so this reads the Keychain itself.
        #expect(KeyStore(service: service).get(account) == "first-value")

        try store.set("second-value", account: account)
        #expect(KeyStore(service: service).get(account) == "second-value")

        try store.delete(account: account)
        #expect(store.get(account) == nil)
        #expect(KeyStore(service: service).get(account) == nil)
        // Deleting a missing item is not an error.
        try store.delete(account: account)
    }

    @Test func keyStoreSeedSkipsTheKeychain() {
        let store = KeyStore(service: "com.captylo.app.tests", seed: ["openrouter": "sk-test"])
        #expect(store.get(KeyStore.Account.openRouter) == "sk-test")
        #expect(KeyStore.Account.openRouter == "openrouter")
        #expect(KeyStore.Account.elevenLabs == "elevenlabs")
    }

    @Test func keyStoreCachesOnlyDefiniteAnswers() {
        let calls = OSAllocatedUnfairLock(initialState: [String: Int]())
        let store = KeyStore(service: "com.captylo.app.tests") { _, account in
            calls.withLock { $0[account, default: 0] += 1 }
            switch account {
            case "present": return KeyStore.ReadResult(value: "sk-1", status: errSecSuccess)
            case "absent": return KeyStore.ReadResult(value: nil, status: errSecItemNotFound)
            default: return KeyStore.ReadResult(value: nil, status: errSecInteractionNotAllowed)
            }
        }
        for _ in 0..<2 {
            #expect(store.get("present") == "sk-1")
            #expect(store.get("absent") == nil)
            #expect(store.get("locked") == nil)
        }
        #expect(calls.withLock { $0 } == ["present": 1, "absent": 1, "locked": 2], "a locked keychain is read again next time")
    }

    @Test func keyStoreLoadTimesOutWhileTheKeychainBlocks() async {
        let gate = DispatchSemaphore(value: 0)
        let store = KeyStore(service: "com.captylo.app.tests") { _, _ in
            gate.wait()
            return KeyStore.ReadResult(value: "sk-late", status: errSecSuccess)
        }
        #expect(await store.load("openrouter", timeout: .milliseconds(50)) == .timedOut)
        gate.signal()
        // The abandoned read still lands in the cache.
        #expect(await store.load("openrouter") == .value("sk-late"))
    }

    @Test func keyStoreLookupTellsAMissingItemFromAnUnreadableOne() async {
        let store = KeyStore(service: "com.captylo.app.tests") { _, account in
            switch account {
            case "present": return KeyStore.ReadResult(value: "sk-1", status: errSecSuccess)
            case "absent": return KeyStore.ReadResult(value: nil, status: errSecItemNotFound)
            case "denied": return KeyStore.ReadResult(value: nil, status: errSecAuthFailed)
            default: return KeyStore.ReadResult(value: nil, status: errSecInteractionNotAllowed)
            }
        }
        #expect(await store.lookup("present") == .found("sk-1"))
        #expect(await store.lookup("absent") == .absent)
        #expect(await store.lookup("denied") == .unreadable(errSecAuthFailed))
        #expect(await store.lookup("locked") == .unreadable(errSecInteractionNotAllowed))
        // Cached answers keep their meaning.
        #expect(await store.lookup("present") == .found("sk-1"))
        #expect(await store.lookup("absent") == .absent)
    }

    @Test func keyStoreLookupTimesOutWhileTheKeychainBlocks() async {
        let gate = DispatchSemaphore(value: 0)
        let store = KeyStore(service: "com.captylo.app.tests") { _, _ in
            gate.wait()
            return KeyStore.ReadResult(value: "sk-late", status: errSecSuccess)
        }
        #expect(await store.lookup("captylo-account", timeout: .milliseconds(50)) == .timedOut)
        gate.signal()
        #expect(await store.lookup("captylo-account") == .found("sk-late"))
    }

    @Test func keyStoreRemoveInBackgroundForgetsAtOnce() {
        let store = KeyStore.inMemory(seed: ["captylo-account": "token"])
        store.removeInBackground(account: "captylo-account")
        #expect(store.get("captylo-account") == nil)
    }

    @Test func keyStoreErrorHasPolishDescription() {
        let error = KeyStoreError.status(errSecAuthFailed)
        let text = error.errorDescription ?? ""
        #expect(text.contains("pęku kluczy"))
        #expect(text.contains("\(errSecAuthFailed)"))
    }
}

// MARK: - Helpers shared by the networking tests

final class Counter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { state.withLock { $0 } }

    func increment() {
        state.withLock { $0 += 1 }
    }
}

func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
        if clock.now - start > timeout {
            Issue.record("Timed out waiting for the condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

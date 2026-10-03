import Foundation
import Security
import os

/// API keys in the file-based login Keychain (gotcha 75): generic passwords under the
/// service `com.captylo.app`. No data-protection keychain (ad-hoc builds have no access
/// group and fail with -34018) and no iCloud sync. Values are cached in memory after the
/// first read so the hot path never touches the Keychain twice.
///
/// `SecItemCopyMatching` can block for as long as an ACL prompt is open (every ad-hoc rebuild
/// changes the code identity), so the hot path uses `load(_:timeout:)`, which reads on a
/// dedicated queue and never on the cooperative pool, and `preload(_:)` warms the cache at launch.
final class KeyStore: Sendable {
    enum Account {
        static let openRouter = "openrouter"
        static let elevenLabs = "elevenlabs"
        /// The Captylo account session token (`AccountStore`).
        static let captyloAccount = "captylo-account"
    }

    /// One Keychain lookup: the value (nil when absent or unreadable) and the raw status.
    struct ReadResult: Sendable {
        let value: String?
        let status: OSStatus

        /// Success and "no such item" are definite answers worth caching; anything else
        /// (locked keychain, denied ACL prompt, interaction not allowed) is retried next time.
        var isCacheable: Bool { status == errSecSuccess || status == errSecItemNotFound }
    }

    /// Outcome of a lookup bounded by a timeout: `load(_:timeout:)` (`KeyLookup`) and the cloud
    /// routes built on it (`CloudRouter`). `.value(nil)` is a definite "nothing there".
    enum Lookup<Value: Sendable>: Sendable {
        case value(Value?)
        case timedOut
    }

    typealias KeyLookup = Lookup<String>

    /// Outcome of `lookup(_:timeout:)`: unlike `Lookup`, an item that could not be read right now
    /// (denied ACL prompt, locked keychain) is not reported as missing.
    enum Presence: Sendable, Equatable {
        case found(String)
        /// A definite miss (`errSecItemNotFound`).
        case absent
        /// Any other failed read; worth retrying later.
        case unreadable(OSStatus)
        case timedOut

        init(_ result: ReadResult) {
            if let value = result.value {
                self = .found(value)
            } else if result.isCacheable {
                self = .absent
            } else {
                self = .unreadable(result.status)
            }
        }
    }

    typealias Reader = @Sendable (_ service: String, _ account: String) -> ReadResult

    static let defaultService = "com.captylo.app"

    let service: String
    /// Cached lookups; `nil` values remember a definite miss so an absent key costs nothing.
    private let cache: OSAllocatedUnfairLock<[String: String?]>
    private let reader: Reader
    /// False for `inMemory()`: `set` and `delete` change only the cache, never the Keychain.
    private let writesKeychain: Bool
    private static let readQueue = DispatchQueue(label: "com.captylo.app.keychain", qos: .userInitiated)

    /// `seed` pre-fills the cache (tests and previews skip the Keychain entirely);
    /// `reader` replaces the Keychain lookup in tests.
    convenience init(service: String = KeyStore.defaultService, seed: [String: String] = [:], reader: Reader? = nil) {
        self.init(service: service, seed: seed, reader: reader, writesKeychain: true)
    }

    private init(service: String, seed: [String: String], reader: Reader?, writesKeychain: Bool) {
        self.service = service
        cache = OSAllocatedUnfairLock(initialState: seed.mapValues { Optional($0) })
        self.reader = reader ?? { service, account in KeyStore.keychainRead(service: service, account: account) }
        self.writesKeychain = writesKeychain
    }

    /// A store that never reads or writes the Keychain: absent items read as missing, writes
    /// stay in memory (tests, the design preview's account).
    static func inMemory(seed: [String: String] = [:]) -> KeyStore {
        KeyStore(
            service: "com.captylo.app.in-memory",
            seed: seed,
            reader: { _, _ in ReadResult(value: nil, status: errSecItemNotFound) },
            writesKeychain: false
        )
    }

    /// The stored value, or nil when the account has no item (or the Keychain is unavailable).
    /// Blocks while the Keychain does; prefer `load(_:timeout:)` off the main thread.
    func get(_ account: String) -> String? {
        read(account).value
    }

    /// Like `get`, but keeps the status so a caller can tell "absent" (`errSecItemNotFound`) from
    /// "unreadable right now" (denied prompt, locked keychain). A cached answer reports the status
    /// it was cached with. Blocks while the Keychain does.
    func read(_ account: String) -> ReadResult {
        if let cached = cache.withLock({ $0[account] }) {
            return ReadResult(value: cached, status: cached == nil ? errSecItemNotFound : errSecSuccess)
        }
        let result = reader(service, account)
        if result.isCacheable {
            // A `set` or `delete` that finished while this read was blocked is newer: keep it.
            cache.withLock { cache in
                if cache.index(forKey: account) == nil {
                    cache[account] = .some(result.value)
                }
            }
        } else {
            Log.app.error("Keychain read failed for \(account, privacy: .public): \(result.status), not cached")
        }
        return result
    }

    /// Non-blocking: the cached value when a definite answer is known, otherwise reads on the
    /// Keychain queue. With a `timeout`, gives up waiting (the read still completes and fills
    /// the cache for the next call).
    func load(_ account: String, timeout: Duration? = nil) async -> KeyLookup {
        if let cached = cache.withLock({ $0[account] }) {
            return .value(cached)
        }
        return await onKeychainQueue(timeout: timeout, timedOut: .timedOut) { .value(self.get(account)) }
    }

    /// Like `load(_:timeout:)`, but keeps "absent" apart from "unreadable right now", so a caller
    /// can act on a definite miss only (the account signs out only when its token is really gone).
    func lookup(_ account: String, timeout: Duration? = nil) async -> Presence {
        if let cached = cache.withLock({ $0[account] }) {
            return cached.map(Presence.found) ?? .absent
        }
        return await onKeychainQueue(timeout: timeout, timedOut: .timedOut) { Presence(self.read(account)) }
    }

    /// Runs `work` on the Keychain queue; with a `timeout`, stops waiting and returns `timedOut`
    /// (the work still finishes and fills the cache for the next call).
    private func onKeychainQueue<T: Sendable>(
        timeout: Duration?,
        timedOut: T,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>(initialState: continuation)
            let finish: @Sendable (T) -> Void = { result in
                pending.withLock { waiting in
                    waiting?.resume(returning: result)
                    waiting = nil
                }
            }
            Self.readQueue.async {
                finish(work())
            }
            if let timeout {
                let components = timeout.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    finish(timedOut)
                }
            }
        }
    }

    /// Warms the cache on the Keychain queue (launch), so the first dictation never waits on it.
    func preload(_ accounts: [String]) {
        Self.readQueue.async {
            for account in accounts {
                _ = self.get(account)
            }
        }
    }

    /// Updates the existing item or adds a new one.
    func set(_ value: String, account: String) throws {
        guard writesKeychain else {
            cache.withLock { $0[account] = .some(value) }
            return
        }
        let data = Data(value.utf8)
        let query = Self.baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Log.app.error("Keychain set failed for \(account, privacy: .public): \(status)")
            throw KeyStoreError.status(status)
        }
        cache.withLock { $0[account] = .some(value) }
    }

    /// Removes the item; a missing item is not an error.
    func delete(account: String) throws {
        guard writesKeychain else {
            cache.withLock { $0[account] = .some(nil) }
            return
        }
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.app.error("Keychain delete failed for \(account, privacy: .public): \(status)")
            throw KeyStoreError.status(status)
        }
        cache.withLock { $0[account] = .some(nil) }
    }

    /// Forgets the value at once and removes the Keychain item on the Keychain queue, so the
    /// caller (the main actor) never waits on an ACL prompt. A `set` that lands before the
    /// removal runs wins: the new item is kept. A failure is only logged.
    func removeInBackground(account: String) {
        cache.withLock { $0[account] = .some(nil) }
        guard writesKeychain else { return }
        let service = service
        Self.readQueue.async {
            let stillForgotten = self.cache.withLock { cache -> Bool in
                if case .some(.none) = cache[account] { return true }
                return false
            }
            guard stillForgotten else { return }
            let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                Log.app.error("Keychain delete failed for \(account, privacy: .public): \(status)")
            }
        }
    }

    // MARK: Keychain

    private static func keychainRead(service: String, account: String) -> ReadResult {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ReadResult(value: nil, status: status)
        }
        return ReadResult(value: String(decoding: data, as: UTF8.self), status: status)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension KeyStore.Lookup: Equatable where Value: Equatable {}

enum KeyStoreError: LocalizedError, Sendable, Equatable {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let code = String(status)
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
            return detail.isEmpty
                ? String(localized: "Nie udało się zapisać klucza w pęku kluczy (kod \(code)).")
                : String(localized: "Nie udało się zapisać klucza w pęku kluczy: \(detail) (kod \(code)).")
        }
    }
}

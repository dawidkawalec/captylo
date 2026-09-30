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
    }

    /// One Keychain lookup: the value (nil when absent or unreadable) and the raw status.
    struct ReadResult: Sendable {
        let value: String?
        let status: OSStatus

        /// Success and "no such item" are definite answers worth caching; anything else
        /// (locked keychain, denied ACL prompt, interaction not allowed) is retried next time.
        var isCacheable: Bool { status == errSecSuccess || status == errSecItemNotFound }
    }

    /// Outcome of `load(_:timeout:)`.
    enum Lookup: Sendable, Equatable {
        case value(String?)
        case timedOut
    }

    typealias Reader = @Sendable (_ service: String, _ account: String) -> ReadResult

    static let defaultService = "com.captylo.app"

    let service: String
    /// Cached lookups; `nil` values remember a definite miss so an absent key costs nothing.
    private let cache: OSAllocatedUnfairLock<[String: String?]>
    private let reader: Reader
    private static let readQueue = DispatchQueue(label: "com.captylo.app.keychain", qos: .userInitiated)

    /// `seed` pre-fills the cache (tests and previews skip the Keychain entirely);
    /// `reader` replaces the Keychain lookup in tests.
    init(service: String = KeyStore.defaultService, seed: [String: String] = [:], reader: Reader? = nil) {
        self.service = service
        cache = OSAllocatedUnfairLock(initialState: seed.mapValues { Optional($0) })
        self.reader = reader ?? { service, account in KeyStore.keychainRead(service: service, account: account) }
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
    func load(_ account: String, timeout: Duration? = nil) async -> Lookup {
        if let cached = cache.withLock({ $0[account] }) {
            return .value(cached)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Lookup, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Lookup, Never>?>(initialState: continuation)
            let finish: @Sendable (Lookup) -> Void = { lookup in
                pending.withLock { waiting in
                    waiting?.resume(returning: lookup)
                    waiting = nil
                }
            }
            Self.readQueue.async {
                finish(.value(self.get(account)))
            }
            if let timeout {
                let components = timeout.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    finish(.timedOut)
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
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.app.error("Keychain delete failed for \(account, privacy: .public): \(status)")
            throw KeyStoreError.status(status)
        }
        cache.withLock { $0[account] = .some(nil) }
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

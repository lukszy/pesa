import Foundation
import Security

/// Secret storage for the OpenRouter API key. The key lives here and nowhere
/// else: nothing in this file writes it to a plain file, logs it, or embeds it
/// in an error.
enum Keychain {
    static let service = "provider-cost-controller"

    /// Error carrying only the opaque `OSStatus`; never the secret.
    struct Failure: Error {
        let status: OSStatus
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Upsert. `SecItemAdd` on an existing account returns `errSecDuplicateItem`,
    /// so update first and add only when there is nothing to update.
    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw Failure(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw Failure(status: addStatus)
        }
    }

    /// Removing an already-absent key is a no-op, not an error: a second
    /// clear-key action must not fail with nothing to remove.
    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Failure(status: status)
        }
    }
}

import Foundation
import Security

/// The API key lives only in the macOS Keychain; it is never written to UserDefaults or any file
enum KeychainStore {
    private static let service = "com.dereklu.diskmanager"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Passing nil or an empty string means remove
    @discardableResult
    static func save(_ value: String?, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var attributes = query(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

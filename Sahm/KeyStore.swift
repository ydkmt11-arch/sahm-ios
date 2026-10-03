import Foundation
import Security

/// The pairing key: Keychain first; UserDefaults only if the Keychain refuses (e.g. an unsigned simulator build).
enum KeyStore {
    private static let service = "com.sahm.app"
    private static let account = "pair-key"
    private static let fallback = "sahm.pairKey"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return UserDefaults.standard.string(forKey: fallback)
    }

    static func save(_ key: String) {
        clear()
        var query = base
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(key, forKey: fallback)
        }
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallback)
    }
}

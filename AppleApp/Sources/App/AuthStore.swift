import Foundation
import Security

/// Encrypted-at-rest storage for the YouTube Music session cookie.
///
/// Upstream uses EncryptedSharedPreferences. On Apple the equivalent is the
/// Keychain, not UserDefaults (which is what PlatformSettings uses for
/// playback toggles). The cookie is a full account grant — it never goes in
/// prefs, logs, or iCloud.
enum AuthStore {
    private static let service = "com.example.bitchord.auth"
    private static let account = "ytmusic.cookie"

    static var cookie: String? {
        get {
            var result: AnyObject?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary)
            guard let value = newValue, let data = value.data(using: .utf8), !value.isEmpty else {
                return
            }
            SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
        }
    }
}

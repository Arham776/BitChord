import Foundation
import Security

/// Encrypted-at-rest storage for the YouTube Music session cookie.
///
/// Upstream uses `EncryptedSharedPreferences`. On Apple the equivalent is the
/// Keychain, not `UserDefaults` (which is what `PlatformSettings` uses for
/// playback toggles). The cookie is a full account grant — it never goes in
/// prefs, logs, or iCloud.
enum AuthStore {
    private static let service = "com.example.bitchord.auth"
    private static let account = "ytmusic.cookie"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static var cookie: String? {
        get {
            var result: AnyObject?
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery() as CFDictionary)
            guard let value = newValue,
                  let data = value.data(using: .utf8),
                  !value.isEmpty else { return }
            var item = baseQuery()
            item[kSecValueData as String] = data
            // Explicit rather than left to the default. This is a credential, and
            // the default for a new generic-password item is `WhenUnlocked` —
            // which would make it unreadable to the background playback path on a
            // device locked since boot, so the session would be a cookie that
            // browses fine in the foreground and vanishes for the one thing that
            // needs it in the background.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Out of iCloud Keychain, and out of any backup that would restore it to
            // a different device. `ThisDeviceOnly` already covers the first; stated
            // rather than implied so the intent survives a refactor.
            item[kSecAttrSynchronizable as String] = false
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// Whether a cookie exists but cannot be read yet.
    ///
    /// `errSecInteractionNotAllowed` is what the Keychain returns for an item whose
    /// accessibility class does not permit reading before first unlock. Worth
    /// distinguishing from "no cookie": the two are different states, and treating
    /// a locked device as a signed-out one silently drops a perfectly good session
    /// and browses as a guest until the next launch.
    static var isLocked: Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecInteractionNotAllowed
    }

    /// Drop the session. Used on sign-out and when a cookie is rejected.
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

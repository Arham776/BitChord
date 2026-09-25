import Foundation
import Security

/// One Keychain accessor, shared by the YouTube session cookie and every other
/// credential the app holds.
///
/// The port previously had [AuthStore] for the cookie and nothing for the rest,
/// so `discord_token` sat in `NSUserDefaults` — plain text, included in backups,
/// and readable by anything with access to the container. Upstream keeps the
/// Discord token, the YouTube cookie, and the WebDAV and SMB passwords together
/// in `EncryptedSharedPreferences` and excludes them from its backup export; this
/// is the same policy on the platform's equivalent facility.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly` rather than the
/// generic-password default of `WhenUnlocked`, so a credential is still readable
/// to the background playback path on a device that has been locked since boot.
/// The `ThisDeviceOnly` half keeps it out of iCloud Keychain and out of any
/// backup that would restore it to a different device.
enum Keychain {
    private static let service = "com.example.bitchord.credentials"

    /// Read a value, or nil when there is none.
    ///
    /// Any failure — a locked Keychain, a malformed item, an OSStatus this code
    /// does not recognise — answers nil rather than throwing, so a credential
    /// that cannot be read degrades to "not signed in" instead of taking the app
    /// down on launch.
    static func get(_ account: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching(baseQuery(account) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store a value, or remove the item when [value] is nil or empty.
    static func put(_ account: String, _ value: String?) {
        // Delete first: adding a duplicate account fails rather than replacing,
        // so a rotated credential would otherwise leave the old one in place.
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, let data = value.data(using: .utf8), !value.isEmpty else { return }

        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// Whether an item exists but cannot be read yet — a device that has not been
    /// unlocked since boot.
    ///
    /// Worth distinguishing from "no credential": they are different states, and
    /// treating a locked device as a signed-out one silently drops a perfectly
    /// good session and browses as a guest until the next launch.
    static func isLocked(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecInteractionNotAllowed
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

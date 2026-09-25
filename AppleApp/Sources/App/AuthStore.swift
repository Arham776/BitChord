import Foundation
import Security
import BitChordShared

/// Encrypted-at-rest storage for the YouTube Music session cookie.
///
/// Upstream uses `EncryptedSharedPreferences`. On Apple the equivalent is the
/// Keychain, not `UserDefaults` — see [Keychain], which this is the cookie's
/// caller of rather than a second implementation of.
enum AuthStore {
    private static let account = "ytmusic.cookie"

    static var cookie: String? {
        get { Keychain.get(account) }
        set { Keychain.put(account, newValue) }
    }

    /// Whether a cookie exists but cannot be read yet — a device that has not
    /// been unlocked since boot. Distinguishable from "not signed in", and worth
    /// distinguishing: they call for opposite actions.
    static var isLocked: Bool { Keychain.isLocked(account) }

    /// Drop the session. Used on sign-out and when a cookie is rejected.
    static func clear() {
        Keychain.clear(account)
    }
}

/// Wires the shared module's Keychain seam to [Keychain] at launch.
///
/// The Discord bearer token, the WebDAV and SMB passwords, and an addon's base
/// URL — which on this protocol can carry a token in its path — all live here
/// rather than in `UserDefaults`. That is upstream's policy, not a preference:
/// its backup export carries a `SECRETS` exclusion list precisely because those
/// values are otherwise exported, and its `EncryptedSharedPreferences` exists so
/// they are not sitting in plain text in the first place.
enum SecretStoreWiring {
    static func install() {
        SecretStoreBridge.shared.setImpl(value: Impl())
    }

    private final class Impl: SecretStoreBridgeImpl {
        func get(key: String) -> String? { Keychain.get(key) }

        func put(key: String, value: String?) { Keychain.put(key, value) }
    }
}

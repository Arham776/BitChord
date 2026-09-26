import Foundation
import Observation
import BitChordShared

/// In-memory sign-in state. The cookie lives in [AuthStore] (Keychain) and
/// is copied into Innertube only through [AuthBridge.applyCookie], which
/// refuses a jar with no SAPISID.
@Observable
final class AuthController {
    var signedIn = false
    var accountName: String?
    var accountEmail: String?
    var accountPhotoUrl: String?
    var loginPresented = false
    /// Home/Explore observe this and reload after sign-in / sign-out.
    var sessionEpoch = 0

    init() {
        // Apply the Keychain cookie before the first Home `.task` so the
        // signed-in browse is not raced by a guest fetch.
        restore()
    }

    /// Why the session could not be read even though one is stored, if so.
    ///
    /// Only set when [AuthStore.isLocked] — the Keychain will not answer before
    /// first unlock. Worth surfacing rather than treating as signed-out, because
    /// "your session is saved but this device has not been unlocked yet" and "you
    /// are not signed in" call for opposite actions.
    var sessionUnavailableReason: String?

    func restore() {
        sessionUnavailableReason = nil
        guard let cookie = AuthStore.cookie else {
            if AuthStore.isLocked {
                sessionUnavailableReason =
                    "Your session is saved but this device has not been unlocked yet."
            }
            return
        }
        guard AuthBridge.shared.applyCookie(cookieHeader: cookie) else {
            // A stored cookie with no signing secret in it is worse than none: it
            // would have every request go out unsigned while the UI claimed
            // otherwise. Drop it rather than keep re-applying it.
            AuthStore.clear()
            return
        }
        signedIn = true
        sessionEpoch += 1
        Task { await refreshAccount() }
    }

    /// The account, pushed to the one place that keeps a copy for anybody else who
    /// wants it.
    ///
    /// Listen Together needs a name and a face for its member rows, and it needs them
    /// on *every* device in the party rather than just this one — so the account has
    /// to travel with a join request rather than each device fetching it. A fetch at
    /// join time would be a visible stall on a LAN-scale feature, so it is cached
    /// here instead and refreshed whenever the account actually changes.
    private func publishAccount() {
        MainActor.assumeIsolated {
            PartyAccountCache.update(
                name: accountName,
                email: accountEmail,
                avatarUrl: accountPhotoUrl
            )
            PartyStore.shared.accountChanged()
        }
    }

    func accept(_ cookieHeader: String) {
        guard AuthBridge.shared.applyCookie(cookieHeader: cookieHeader) else { return }
        AuthStore.cookie = cookieHeader
        signedIn = true
        loginPresented = false
        sessionEpoch += 1
        Task { await refreshAccount() }
    }

    func signOut() {
        AuthStore.clear()
        _ = AuthBridge.shared.applyCookie(cookieHeader: nil)
        signedIn = false
        accountName = nil
        accountEmail = nil
        accountPhotoUrl = nil
        sessionUnavailableReason = nil
        sessionEpoch += 1
        publishAccount()
    }

    private func refreshAccount() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AuthBridge.shared.ensureSession(callback: SessionDoneAdapter { _, _ in
                AccountBridge.shared.account(callback: AccountCallbackAdapter { json, _ in
                    Task { @MainActor in
                        if let json, let info = try? JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8)) {
                            self.accountName = info.name
                            self.accountEmail = info.email
                            self.accountPhotoUrl = info.photoUrl
                        }
                        self.publishAccount()
                        cont.resume()
                    }
                })
            })
        }
    }
}

private final class SessionDoneAdapter: AuthBridgeDoneCallback {
    private let onResult: (Bool, String?) -> Void
    init(onResult: @escaping (Bool, String?) -> Void) { self.onResult = onResult }
    func onResult(ok: Bool, message: String?) { onResult(ok, message) }
}

private final class AccountCallbackAdapter: AccountBridgeAccountCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

private struct AccountInfo: Decodable {
    let name: String
    let email: String
    let photoUrl: String?
}

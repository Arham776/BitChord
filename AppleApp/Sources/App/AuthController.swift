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

    func restore() {
        guard let cookie = AuthStore.cookie else { return }
        guard AuthBridge.shared.applyCookie(cookieHeader: cookie) else {
            AuthStore.cookie = nil
            return
        }
        signedIn = true
        Task { await refreshAccount() }
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
        AuthStore.cookie = nil
        _ = AuthBridge.shared.applyCookie(cookieHeader: nil)
        signedIn = false
        accountName = nil
        accountEmail = nil
        accountPhotoUrl = nil
        sessionEpoch += 1
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

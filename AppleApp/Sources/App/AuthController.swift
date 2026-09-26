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
            // The stored cookie is *kept*.
            //
            // It used to be cleared here, on the reasoning that a jar with no
            // signing secret is worse than none. But a stored cookie is the only
            // evidence that the listener ever signed in, and throwing it away means
            // a refusal costs them the session permanently — the one remedy left
            // is to sign in again, which is the thing they were already doing. So a
            // refusal is reported and the cookie stays, and the next launch tries
            // again with whatever the state was by then.
            //
            // The cost of keeping it is bounded and visible: the app reports
            // itself signed out, so nothing goes out claiming to be signed in. A
            // session that is silently gone is a far worse failure than one that is
            // visibly gone.
            sessionUnavailableReason =
                "Your saved session could not be restored. Sign in again to continue."
            return
        }
        signedIn = true
        sessionEpoch += 1
        refreshAccounts()
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

    /// Installs a freshly captured session.
    ///
    /// The cookie is written to the Keychain **first**, and the refusal check
    /// comes after. The other way round, a jar that was refused was never stored —
    /// so a refusal cost the listener the sign-in they had just completed, and the
    /// next launch was signed out. Writing first means a refusal leaves a stored
    /// cookie that the next attempt can still be judged against, and since
    /// [restore] no longer destroys what it cannot apply, the failure is recoverable
    /// rather than terminal.
    func accept(_ cookieHeader: String) {
        AuthStore.cookie = cookieHeader
        guard AuthBridge.shared.applyCookie(cookieHeader: cookieHeader) else {
            // Visible rather than silent: the listener pressed Continue and the
            // app is not signed in, and saying nothing is what made this look like
            // the sign-in had worked.
            sessionUnavailableReason =
                "Google gave a session this app could not use. Try signing in again."
            return
        }
        sessionUnavailableReason = nil
        signedIn = true
        loginPresented = false
        sessionEpoch += 1
        // A new session is a new identity, so the account's own channels have to be
        // read afresh — the listen-as list belongs to the account that is now
        // active, and carrying the old one across would offer the wrong channel.
        recordCurrentAccount()
        Task { await refreshAccount() }
    }

    /// Records the signed-in account, with the identity the session is already
    /// acting as as its one channel.
    ///
    /// The default channel rather than the account's full channel list: upstream
    /// enumerates every channel the account owns, and that is a different call
    /// this app does not make. What *is* already known is the identity the
    /// requests are being sent as — the shell's own, or the override a listener
    /// picked — and that is exactly the one the selector has to offer first.
    ///
    /// Best-effort by design. The session works whether or not this succeeds, and
    /// the channel list is only needed for the selector, so a failure is not
    /// surfaced: a listener who has just signed in should not be told their
    /// sign-in did not work over a channel list.
    private func recordCurrentAccount() {
        guard let cookie = AuthStore.cookie, !cookie.isEmpty else { return }
        // Captured up front and read on the main actor at the end, rather than
        // reached through `self` from two nested closures — the account name is
        // only the display label for this record, and it is not worth an
        // explicit capture chain to have the freshest value of.
        let name = accountName
        let email = accountEmail
        AuthBridge.shared.ensureSession(callback: SessionDoneAdapter { ok, _ in
            guard ok else { return }
            AuthBridge.shared.currentIdentity(
                callback: IdentityDoneAdapter { pageId, dataSyncId, authUser in
                    guard let dataSyncId, !dataSyncId.isEmpty else { return }
                    let id = AccountSessionsKt.sessionIdOf(
                        cookie: cookie, dataSyncId: dataSyncId
                    )
                    let profile = AccountProfile(
                        profileId: pageId ?? dataSyncId,
                        name: name ?? email ?? "YouTube Music",
                        pageId: pageId,
                        dataSyncId: dataSyncId,
                        authUser: authUser
                    )
                    Task { @MainActor in
                        self.record(account: AccountSummary(
                            id: id,
                            name: name ?? "",
                            email: email ?? "",
                            cookie: cookie,
                            profiles: [profile]
                        ))
                    }
                }
            )
        })
    }

    func signOut() {
        // Upstream's sign-out removes the *account*, not just the session: the
        // credential is what the account is, so forgetting one is the same act.
        // Leaving a stored account behind after "sign out" would let a later
        // sign-in silently resume the old identity.
        AccountStore.shared.forget(accountId: AccountStore.shared.activeAccount()?.accountId ?? "")
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

    // ---- Listening as --------------------------------------------------------

    /// The stored accounts, in the order they were added. Bumped by
    /// [sessionEpoch] rather than observed directly: the store is Kotlin and
    /// this is an `@Observable` class, and a second source of truth for "who is
    /// signed in" is precisely the thing that made this feature hard to get
    /// right in the first place.
    private(set) var accounts: [AccountSummary] = []

    /// The YouTube identity currently in effect, if any. Null means the shell's
    /// own default identity, which is the correct answer for a signed-out
    /// listener and for a Google account whose channel list has not been read.
    private(set) var listeningAs: AccountSummary?

    /// Records a signed-in account and selects it.
    func record(account: AccountSummary) {
        // Built as the shared module's own records rather than passing the Swift
        // value types across: the store persists exactly what it is handed, and
        // a second shape would be a second thing that could disagree about a field.
        let profiles = account.profiles.map { profile in
            YouTubeProfile(
                profileId: profile.id,
                name: profile.name,
                handle: profile.handle,
                avatar: profile.avatar,
                pageId: profile.pageId,
                dataSyncId: profile.dataSyncId,
                authUser: profile.authUser,
                isBrandAccount: false
            )
        }
        AccountStore.shared.record(
            accountId: account.id,
            cookie: account.cookie,
            name: account.name,
            email: account.email,
            profiles: profiles
        )
        refreshAccounts()
    }

    /// Selects an identity, for the list UI and for the avatar's swipe.
    ///
    /// Both go through here rather than calling the store, so the account list,
    /// the "listening as" label and the request headers cannot be updated by two
    /// different paths and left disagreeing.
    func select(accountId: String?, profileId: String?) {
        AccountStore.shared.select(accountId: accountId, profileId: profileId)
        refreshAccounts()
    }

    /// Moves to the next or previous identity. False at either end, so a swipe
    /// past the last one does nothing visible rather than wrapping.
    @discardableResult
    func stepProfile(forward: Bool) -> Bool {
        let moved = AccountStore.shared.step(forward: forward)
        if moved { refreshAccounts() }
        return moved
    }

    private func refreshAccounts() {
        let summaries: [AccountSummary] = AccountStore.shared.accounts().map { AccountSummary($0) }
        accounts = summaries
        if let selection = AccountStore.shared.activeSelection() {
            listeningAs = AccountSummary(selection.account, active: selection.profile)
        } else {
            listeningAs = summaries.first
        }
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

private final class IdentityDoneAdapter: AuthBridgeIdentityCallback {
    private let onResult: (String?, String?, String?) -> Void
    init(onResult: @escaping (String?, String?, String?) -> Void) { self.onResult = onResult }
    func onResult(pageId: String?, dataSyncId: String?, authUser: String?) {
        onResult(pageId, dataSyncId, authUser)
    }
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

/// One signed-in Google account and the YouTube identities under it.
///
/// A Swift value rather than a view of the Kotlin record, because the UI needs
/// to compare identities for equality to decide what is selected — and asking a
/// Kotlin data class for that from Swift means two object graphs and an
/// `isEqual` that may or may not be structural.
struct AccountSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    let cookie: String
    let profiles: [AccountProfile]

    /// Only set on the summary that represents the current selection, so a list
    /// row and the header avatar can be told apart by identity rather than by
    /// each asking the store again.
    var activeProfileId: String? = nil

    init(_ session: GoogleAccountSession, active: YouTubeProfile? = nil) {
        id = session.accountId
        name = session.name
        email = session.email
        cookie = session.cookie
        profiles = session.profiles.map(AccountProfile.init)
        activeProfileId = (active ?? session.profiles.first)?.profileId
    }

    init(
        id: String, name: String, email: String, cookie: String,
        profiles: [AccountProfile], activeProfileId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.cookie = cookie
        self.profiles = profiles
        self.activeProfileId = activeProfileId
    }

    /// What to show where a name is wanted. A Google account whose display name
    /// has not been read yet still has an email, and an empty label in a
    /// selector is worse than a rough one.
    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return String(id.prefix(8))
    }

    var activeProfile: AccountProfile? {
        profiles.first { $0.id == activeProfileId } ?? profiles.first
    }
}

/// One YouTube identity — a personal channel or a brand channel.
struct AccountProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let handle: String
    let avatar: String?
    let pageId: String?
    let dataSyncId: String?
    let authUser: String?

    init(
        profileId: String, name: String, handle: String = "", avatar: String? = nil,
        pageId: String? = nil, dataSyncId: String? = nil, authUser: String? = nil
    ) {
        id = profileId
        self.name = name
        self.handle = handle
        self.avatar = avatar
        self.pageId = pageId
        self.dataSyncId = dataSyncId
        self.authUser = authUser
    }

    init(_ profile: YouTubeProfile) {
        id = profile.profileId
        name = profile.name
        handle = profile.handle
        avatar = profile.avatar
        pageId = profile.pageId
        dataSyncId = profile.dataSyncId
        authUser = profile.authUser
    }

    var subtitle: String {
        handle.isEmpty ? name : handle
    }
}

import Foundation
import Observation
import BitChordShared

/// In-memory sign-in state. The cookie lives in [AuthStore] (Keychain) and
/// is copied into Innertube only through [AuthBridge.applyCookie], which
/// refuses a jar with no SAPISID.
@MainActor @Observable
final class AuthController {
    var signedIn = false
    var accountName: String?
    var accountEmail: String?
    var accountPhotoUrl: String?
    var loginPresented = false
    /// Home/Explore observe this and reload after sign-in / sign-out.
    var sessionEpoch = 0 {
        didSet { PageSession.reset(); CacheStatus.shared.reset(); LikeStore.shared.clear() }
    }

    init() {
        // AccountStore reads its encrypted blob during restore. Install the
        // Keychain bridge before the first view (and its feed task) exists.
        SecretStoreWiring.install()
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
        AccountStore.shared.restore()
        // Existing single-account installs only have the legacy cookie. Once a
        // validated account is recorded, the account store becomes authoritative.
        guard let cookie = AccountStore.shared.activeAccount()?.cookie ?? AuthStore.cookie else {
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
    /// Validate the candidate against the page's chosen identity before writing
    /// it. A rejected jar must never replace a session that already worked.
    ///
    /// The page's own identity is adopted before anything validates it — port of
    /// upstream `onWebSession`. The shell fetch can only ever report the default
    /// channel, and the listener just chose one by hand; validating first and
    /// adopting after would check the wrong identity and store the wrong one.
    /// The screen stays open until `onComplete` fires, so a half-finished channel
    /// chooser can never become a durable broken account.
    func accept(_ session: SignInCapture, onComplete: ((Bool) -> Void)? = nil) {
        let previousCookie = AccountStore.shared.activeAccount()?.cookie ?? AuthStore.cookie
        guard session.loggedIn,
              AuthBridge.shared.hasApiSid(cookieHeader: session.cookie),
              AuthBridge.shared.applyCookie(cookieHeader: session.cookie)
        else {
            // Visible rather than silent: the listener confirmed and the app is
            // not signed in, and saying nothing is what made this look like the
            // sign-in had worked.
            sessionUnavailableReason =
                "Google gave a session this app could not use. Try signing in again."
            onComplete?(false)
            return
        }
        AuthBridge.shared.adoptSessionScope(
            pageId: session.pageId,
            dataSyncId: session.dataSyncId,
            authUser: session.authUser,
            visitorData: session.visitorData,
            clientVersion: session.clientVersion,
            loggedIn: true
        )
        let generation = PageSession.generation()
        AuthBridge.shared.ensureSession(callback: SessionDoneAdapter { ok, _ in
            guard ok else {
                Task { @MainActor in
                    guard PageSession.generation() == generation else { onComplete?(false); return }
                    self.restorePreviousSession(cookie: previousCookie)
                    self.sessionUnavailableReason =
                        "Google gave a session this app could not use. Try signing in again."
                    onComplete?(false)
                }
                return
            }
            AccountBridge.shared.account(callback: AccountCallbackAdapter { json, _ in
                Task { @MainActor in
                    guard PageSession.generation() == generation else { onComplete?(false); return }
                    guard let json,
                          let info = try? JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
                    else {
                        self.restorePreviousSession(cookie: previousCookie)
                        self.sessionUnavailableReason =
                            "Google gave a session this app could not use. Try signing in again."
                        onComplete?(false)
                        return
                    }
                    // The account's own channels are the page's choice, not the
                    // shell's default: the ids come from the confirmed page and
                    // only the display name comes from the server.
                    let id = self.accounts.first(where: {
                        !info.email.isEmpty && $0.email.caseInsensitiveCompare(info.email) == .orderedSame
                    })?.id ?? AccountSessionsKt.sessionIdOf(
                        cookie: session.cookie, dataSyncId: session.dataSyncId
                    )
                    let profileId = AccountSessionsKt.profileIdOf(
                        pageId: session.pageId, dataSyncId: session.dataSyncId, name: info.name
                    )
                    guard self.record(account: AccountSummary(
                        id: id,
                        name: info.name,
                        email: info.email,
                        cookie: session.cookie,
                        profiles: [AccountProfile(
                            profileId: profileId,
                            name: info.name,
                            pageId: session.pageId,
                            dataSyncId: session.dataSyncId,
                            authUser: session.authUser
                        )]
                    )) else {
                        self.restorePreviousSession(cookie: previousCookie)
                        self.sessionUnavailableReason =
                            "Your account was verified, but its session could not be saved. Try again."
                        onComplete?(false)
                        return
                    }
                    // The legacy single-cookie key is a migration mirror. The
                    // validated account store is the source of truth on launch.
                    _ = AuthStore.save(session.cookie)
                    self.sessionUnavailableReason = nil
                    self.signedIn = true
                    self.sessionEpoch += 1
                    self.accountName = info.name
                    self.accountEmail = info.email
                    self.accountPhotoUrl = info.photoUrl
                    self.publishAccount()
                    Task { await self.refreshAccount() }
                    onComplete?(true)
                }
            })
        })
    }

    private func restorePreviousSession(cookie: String?) {
        if AccountStore.shared.activeAccount() != nil {
            AccountStore.shared.restore()
        } else {
            _ = AuthBridge.shared.applyCookie(cookieHeader: cookie)
            AuthBridge.shared.clearChannelOverride()
        }
    }

    func signOut() {
        // Upstream's sign-out removes the *account*, not just the session: the
        // credential is what the account is, so forgetting one is the same act.
        // Leaving a stored account behind after "sign out" would let a later
        // sign-in silently resume the old identity.
        guard AuthStore.clear() else {
            sessionUnavailableReason = "The session could not be removed from Keychain. Try again after unlocking this device."
            return
        }
        guard AccountStore.shared.forget(accountId: AccountStore.shared.activeAccount()?.accountId ?? "") else {
            sessionUnavailableReason = "The account could not be removed from Keychain. Try again after unlocking this device."
            return
        }
        Task { await PageRepository.shared.invalidate() }
        if let remaining = AccountStore.shared.activeAccount() {
            AccountStore.shared.restore()
            _ = AuthStore.save(remaining.cookie)
            signedIn = true
            sessionEpoch += 1
            refreshAccounts()
            accountName = listeningAs?.displayName
            accountEmail = listeningAs?.email
            accountPhotoUrl = listeningAs?.activeProfile?.avatar
            publishAccount()
            Task { await refreshAccount() }
            return
        }
        _ = AuthBridge.shared.applyCookie(cookieHeader: nil)
        signedIn = false
        accountName = nil
        accountEmail = nil
        accountPhotoUrl = nil
        sessionUnavailableReason = nil
        sessionEpoch += 1
        refreshAccounts()
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
    @discardableResult
    func record(account: AccountSummary) -> Bool {
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
        let saved = AccountStore.shared.record(
            accountId: account.id,
            cookie: account.cookie,
            name: account.name,
            email: account.email,
            profiles: profiles
        )
        refreshAccounts()
        return saved
    }

    /// Selects an identity, for the list UI and for the avatar's swipe.
    ///
    /// Both go through here rather than calling the store, so the account list,
    /// the "listening as" label and the request headers cannot be updated by two
    /// different paths and left disagreeing.
    func select(accountId: String?, profileId: String?) {
        let previous = AccountStore.shared.activeSelection()
        AccountStore.shared.select(accountId: accountId, profileId: profileId)
        refreshAccounts()
        if previous?.account.accountId != AccountStore.shared.activeSelection()?.account.accountId
            || previous?.profile.profileId != AccountStore.shared.activeSelection()?.profile.profileId {
            sessionEpoch += 1
            accountName = listeningAs?.displayName
            accountEmail = listeningAs?.email
            accountPhotoUrl = listeningAs?.activeProfile?.avatar
            publishAccount()
            Task { await refreshAccount() }
        }
    }

    /// Moves to the next or previous identity. False at either end, so a swipe
    /// past the last one does nothing visible rather than wrapping.
    @discardableResult
    func stepProfile(forward: Bool) -> Bool {
        let moved = AccountStore.shared.step(forward: forward)
        if moved {
            refreshAccounts()
            sessionEpoch += 1
            accountName = listeningAs?.displayName
            accountEmail = listeningAs?.email
            accountPhotoUrl = listeningAs?.activeProfile?.avatar
            publishAccount()
            Task { await refreshAccount() }
        }
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
        let epoch = sessionEpoch
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AuthBridge.shared.ensureSession(callback: SessionDoneAdapter { ok, message in
                guard ok else {
                    Task { @MainActor in
                        if self.sessionEpoch == epoch { self.sessionUnavailableReason = message ?? "Your saved session could not be verified." }
                        cont.resume()
                    }
                    return
                }
                AccountBridge.shared.account(callback: AccountCallbackAdapter { json, message in
                    Task { @MainActor in
                        if self.signedIn, self.sessionEpoch == epoch,
                           let json, let info = try? JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8)) {
                            self.accountName = info.name
                            self.accountEmail = info.email
                            self.accountPhotoUrl = info.photoUrl
                            self.sessionUnavailableReason = nil
                            self.publishAccount()
                        } else if self.signedIn, self.sessionEpoch == epoch {
                            self.sessionUnavailableReason = message ?? "Your saved session could not be verified."
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

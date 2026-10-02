import Foundation
import Observation

/// A session lifted out of the sign-in web view — port of upstream's
/// `CapturedSession` in `auth/WebSession.kt`.
///
/// The identity fields come from the live page's `ytcfg` rather than from a later
/// server-side fetch of the shell, and that is the entire point. Which channel
/// YouTube Music serves by default is not a question this app gets to answer, but
/// which channel the page in front of the listener is *currently* showing is not
/// a question at all — it is written down in the page. Reading it there is what
/// lets "switch to the channel I want, then save" work.
struct SignInCapture: Equatable {
    /// The cookie jar, as a request header.
    var cookie: String
    /// `DELEGATED_SESSION_ID` — set only while a brand channel is selected.
    var pageId: String?
    /// Active identity used as `context.user.onBehalfOfUser`.
    var dataSyncId: String?
    /// `SESSION_INDEX` — which Google account in the cookie jar.
    var authUser: String?
    var visitorData: String?
    var clientVersion: String?
    /// Whether the page reported itself signed in at all.
    var loggedIn: Bool

    /// The probe's result, or nil for anything that isn't the object it promises.
    ///
    /// `WKWebView.evaluateJavaScript` hands back a natively-decoded object for a
    /// JS object — `[String: Any]` — not the JSON string Android's
    /// `evaluateJavascript` returns. The previous port read it as a string, so the
    /// cast failed on every signed-in page and Continue could never succeed: the
    /// session stayed in the web view and the app stayed signed out. Both shapes
    /// are accepted so the rule is stated once and the platform difference cannot
    /// reintroduce the bug by changing which branch runs.
    static func parse(jsResult raw: Any?) -> SignInCaptureFields? {
        if let dict = raw as? [String: Any] {
            return fields(from: dict)
        }
        if let text = raw as? String,
           let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            return fields(from: object)
        }
        return nil
    }

    private static func fields(from dict: [String: Any]) -> SignInCaptureFields {
        SignInCaptureFields(
            loggedIn: string(dict["loggedIn"]) == "true",
            pageId: nonBlank(string(dict["pageId"])),
            dataSyncId: nonBlank(string(dict["dataSyncId"])),
            authUser: nonBlank(string(dict["authUser"])),
            visitorData: nonBlank(string(dict["visitorData"])),
            clientVersion: nonBlank(string(dict["clientVersion"]))
        )
    }

    /// A JS value is either absent, null, or something stringifiable. `NSNull`
    /// is what a `null` in the object arrives as, and treating it as the string
    /// `"null"` would be an identity made of nothing.
    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// YouTube commonly exposes `DATASYNC_ID` as `account||delegated`; the second
    /// half is the active identity, while plain accounts can leave it empty.
    /// Same rule as upstream `normalizeDataSyncId` and shared `Innertube`.
    static func normalizeDataSyncId(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        guard let split = value.range(of: "||") else { return value }
        let after = String(value[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { return after }
        let before = String(value[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return before.isEmpty ? nil : before
    }
}

/// The page's own account configuration, before it is paired with a cookie.
struct SignInCaptureFields: Equatable {
    var loggedIn: Bool
    var pageId: String?
    var dataSyncId: String?
    var authUser: String?
    var visitorData: String?
    var clientVersion: String?
}

/// Display metadata for the selected YouTube identity. Never a credential and
/// never the app's previously saved account: it comes from this browser's menu.
struct SignInProfilePreview: Equatable {
    let name: String
    let subtitle: String?
    let avatarURL: URL?

    var initials: String {
        String(name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap { $0.first }.map { String($0) }.joined()).uppercased()
    }

    static func parse(_ data: Data) -> SignInProfilePreview? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let header = accountHeader(in: root),
              let name = text(header["accountName"]) else { return nil }
        let subtitle = text(header["email"]) ?? text(header["channelHandle"])
        let photos = (header["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let photo = photos.sorted { ($0["width"] as? Int ?? 0) > ($1["width"] as? Int ?? 0) }
            .compactMap { safeAvatarURL($0["url"] as? String) }.first
        return SignInProfilePreview(name: name, subtitle: subtitle, avatarURL: photo)
    }

    private static func accountHeader(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if let header = object["activeAccountHeaderRenderer"] as? [String: Any] { return header }
            for child in object.values { if let header = accountHeader(in: child) { return header } }
        } else if let array = value as? [Any] {
            for child in array { if let header = accountHeader(in: child) { return header } }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let runs = (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        let value = ((runs?.isEmpty == false ? runs : object["simpleText"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func safeAvatarURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw),
              url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              ["googleusercontent.com", "ggpht.com", "ytimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        return url
    }
}

/// The identity displayed by the confirmation card must still be the one the
/// page reports when it is confirmed. Display names are not identity keys.
struct SignInProfileScope: Equatable {
    let pageId: String?
    let dataSyncId: String?
    let authUser: String?
    init(_ fields: SignInCaptureFields) {
        pageId = fields.pageId
        dataSyncId = fields.pageId ?? SignInCapture.normalizeDataSyncId(fields.dataSyncId)
        authUser = fields.authUser
    }
}

/// Presentation state only: inspecting the page never saves a session. Keeping
/// this independent of WebKit lets the incomplete-login and retry paths be
/// checked without credentials or a browser.
@Observable
final class LoginFlow {
    private(set) var reachedMusicOrigin = false
    private(set) var signedInProfileAvailable = false
    private(set) var choosingProfile = false
    private(set) var checkingPage = false
    var taking = false
    var profile: SignInProfilePreview?
    var profileScope: SignInProfileScope?
    var loadingProfile = false
    var passkeyHelp = false
    var selectingPassword = false
    var passwordAdvice: String?
    var captureFailedMessage: String?
    var refusal: SignInNavigation.Refusal?
    var offOriginHost: String?
    let session = SignInSession()

    var pageReady: Bool {
        // Match upstream: arriving on Music enables an explicit attempt. A
        // delayed ytcfg must not strand the listener without a retry button;
        // takeSession still requires LOGGED_IN at the moment of capture.
        reachedMusicOrigin && !checkingPage && !loadingProfile && !taking
    }

    var showsCompletion: Bool {
        taking || (reachedMusicOrigin && !choosingProfile && (checkingPage || signedInProfileAvailable))
    }

    func navigating(to url: URL?) {
        reachedMusicOrigin = SignInNavigation.isMusicOrigin(url)
        signedInProfileAvailable = false
        checkingPage = reachedMusicOrigin
        captureFailedMessage = nil
        profile = nil
        profileScope = nil
        loadingProfile = false
        passkeyHelp = SignInNavigation.isGooglePasskeyPage(url)
        passwordAdvice = nil
        offOriginHost = SignInNavigation.isSignInHost(url) ? nil : url?.host
        refusal = nil
    }

    func inspectedPage(loggedIn: Bool) {
        checkingPage = false
        signedInProfileAvailable = reachedMusicOrigin && loggedIn
    }

    func chooseProfile() {
        choosingProfile = true
        profile = nil
        profileScope = nil
        captureFailedMessage = nil
    }

    func captureFailed(_ reason: String) {
        taking = false
        captureFailedMessage = reason
    }

    func captureSucceeded() {
        taking = false
        captureFailedMessage = nil
    }

    var prompt: String? {
        if let captureFailedMessage { return captureFailedMessage }
        if passkeyHelp {
            return passwordAdvice ?? "Passkeys are unavailable in this sign-in window. Use your password or choose another method on Google."
        }
        if let refusal { return refusal.summary }
        if reachedMusicOrigin {
            return signedInProfileAvailable
                ? "Choose your profile using the avatar, then tap Use This Profile to finish signing in to BitChord."
                : "Finish signing in and selecting your profile, then tap Use This Profile."
        }
        if let offOriginHost { return SignInNavigation.offSignInHostAdvice(host: offOriginHost) }
        return nil
    }
}

/// Written while WebKit is made, outside observation, so SwiftUI cannot discard
/// the confirmation action as an observable mutation during a view update.
final class SignInSession {
    var take: (() -> Void)?
    var usePassword: (() -> Void)?
}

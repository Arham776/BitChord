import Foundation

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

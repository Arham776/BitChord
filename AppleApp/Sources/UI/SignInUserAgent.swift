import Foundation

/// The user agent the sign-in web view identifies as.
///
/// ## Why this exists at all
///
/// Google refuses to sign in from an embedded web view. The page in the report
/// said so in as many words — "This browser or app may not be secure" — and it is
/// Google's block, not a bug in the flow: `accounts.google.com` allowlists
/// browser engines it recognises, Android's `WebView` is one of them, and Apple's
/// `WKWebView` is not.
///
/// ## Why upstream never hits this
///
/// Upstream sets no user agent at all. It uses a stock `android.webkit.WebView`
/// with the same login URL — byte for byte the same string — and Google accepts it,
/// because on Android that engine *is* the system browser. So there is nothing
/// upstream does that this is missing; the difference is the platform, and the
/// remedy is to present the engine as a browser Google recognises.
///
/// ## Why not `ASWebAuthenticationSession`
///
/// That is Apple's standard for web sign-in, and it is the right answer for OAuth
/// *because it hands back the URL it redirected to*. YouTube Music's sign-in
/// redirects nowhere useful — it sets a cookie jar and lands on a page — so there
/// is no callback to take. `ASWebAuthenticationSession` shares no cookie store
/// with the app, and a `WKWebView` is the only thing on iOS that can both be
/// accepted by Google and have its jar read afterwards. Which is also why
/// upstream uses a web view rather than a custom tab.
///
/// ## Why the version in here is a constant
///
/// `Version/17.6` is the Safari version token, and it is the one part of the
/// string that has to be a plausible number rather than a true one. Google
/// identifies the *family* — Safari on macOS — and the token's job is to say so;
/// nothing validates that it is current, and a wrong minor version is ignored
/// where no version at all is not. It is a constant rather than a lookup because
/// the true value is not reachable from an app: Safari's version is not public
/// API, and inventing a mapping from the OS version to Safari's would be fake
/// precision that also rots. It is isolated here so bumping it is one edit.
enum SignInUserAgent {

    /// The whole string, for a WKWebView running on `osVersion`.
    ///
    /// `osVersion` is the *operating system* version and only appears in the
    /// platform token, which Google does not read — it is there because a UA
    /// without one is not shaped like a real one.
    static func desktopSafari(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let major = osVersion.majorVersion
        let minor = osVersion.minorVersion
        let patch = osVersion.patchVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Safari/605.1.15"
            + " (bitchord; macOS \(major).\(minor).\(patch))"
    }

    /// The Safari version token. See the type's note on why it is a constant.
    static let safariVersion = "17.6"

    /// Whether the engine's own agent has to be replaced.
    ///
    /// The question is "will Google accept this one", not "is this a mobile one" —
    /// a UA that is empty, or that is not Mozilla's, or that names no browser
    /// family, is refused just as firmly as a phone's, and a check which only
    /// spotted `Mobile/` would wave all of those through.
    ///
    /// Measured on both platforms, and the answer differs. A macOS `WKWebView`
    /// already sends `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)
    /// AppleWebKit/605.1.15 (KHTML, like Gecko)` — desktop, but naming no
    /// browser at all, so it is replaced too. An iOS one sends `Mozilla/5.0
    /// (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML,
    /// like Gecko) Mobile/15E148 Safari/604.1`, which is a phone.
    ///
    /// So in practice this replaces on both. It is a positive test rather than one
    /// string comparison because the *shape* of an acceptable agent is the thing
    /// that matters, and spelling the shape out is what makes a change to WebKit's
    /// default visible here rather than only on a device.
    static func needsReplacing(defaultAgent: String) -> Bool {
        !isAcceptable(defaultAgent)
    }

    /// Whether an agent already identifies as a browser Google recognises.
    static func isAcceptable(_ agent: String) -> Bool {
        guard !agent.isEmpty else { return false }
        guard !agent.contains("Mobile/") else { return false }
        guard agent.hasPrefix("Mozilla/") else { return false }
        // The Safari tokens are what name the family. WebKit's own macOS agent
        // carries the WebKit build and nothing else, and a UA with a WebKit build
        // and no browser named is a browser Google has no rule for.
        guard agent.contains("Safari/") else { return false }
        guard agent.contains("Version/") else { return false }
        return true
    }
}

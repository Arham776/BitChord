import Foundation

/// What the sign-in web view is allowed to navigate to.
///
/// Its own file, and free of WebKit, for two reasons. The obvious one is that it
/// can then be checked without a web view, a window server session or a human —
/// see `scripts/check-signin.sh`. The better one is that a navigation rule is a
/// *decision about a URL*, and burying it inside a `WKNavigationDelegate` is what
/// makes it untestable: a bug there is invisible until somebody tries to sign in,
/// and by then it looks like a broken account rather than a broken rule.
///
/// ## The rule
///
/// Google signs in across several hosts — `accounts.google.com` for the password
/// and every challenge, `music.youtube.com` for the session it hands back — and
/// each of those has to load or nothing works. Anything else on the `web` is a
/// link the listener tapped: a help page, a privacy policy, a blog post, and
/// those are opened outside rather than swallowed with no feedback.
///
/// Every other scheme is **refused**, and that is the whole of the reported bug.
/// A music.youtube.com page carries links out to the YouTube Music app and to the
/// App Store, and a web view hands `youtube://` and `itms-apps://` to the system —
/// which opens another app mid-sign-in and takes the session with it.
enum SignInNavigation {

    enum Decision: Equatable {
        /// Load it in the sign-in web view.
        case allow
        /// Cancel it here and open it where the listener asked for — Safari.
        case openOutside
        /// Cancel it and do nothing else. Any non-`http(s)` scheme lands here.
        case refuse
    }

    /**
     * The hosts the sign-in is allowed to load.
     *
     * A fixed list on purpose: the policy is "Google's sign-in and music pages",
     * not "anything that resolves to somewhere". Matched on a dot-delimited
     * suffix, so `accounts.google.co.uk` works and
     * `accounts.google.com.evil.test` does not — the dot is the entire difference
     * between those two, and a `contains` check would accept the second.
     */
    static let googleDomains = [
        "google.com",
        "googleapis.com",
        "gstatic.com",
        "youtube.com",
        "ytimg.com",
    ]

    static func decision(for url: URL?) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse }
        // Anything that is not a web page is refused before its host is even read,
        // so `youtube://` and `itms-apps://` cannot be argued into the allow path
        // by a hostname that happens to look right.
        guard scheme == "https" || scheme == "http" else { return .refuse }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refuse }
        if googleDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return .allow
        }
        return .openOutside
    }
}

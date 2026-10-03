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
/// ## A sign-in has no exits
///
/// Google signs in across several hosts and **none of them are ours to
/// enumerate**: `accounts.google.com` for the password and every challenge,
/// `music.youtube.com` for the session it hands back, and whatever a regional
/// account, an enterprise IdP or a consent interstitial puts in between. So this
/// policy decides nothing about hosts. Every `http(s)` URL **loads**, and the only
/// refusals are schemes that are not web pages at all.
///
/// ## Why the allow list that used to be here was the bug
///
/// It read any `http(s)` URL outside five Google domains as "a link the listener
/// tapped" and opened it outside — which is `UIApplication.open`, and for a domain
/// the system has handed to an app that means **the YouTube Music app**, not
/// Safari. The session then finished in another app's cookie jar, ours was never
/// written, and the report was "the YouTube Music app is capturing the sign-in and
/// our app remains signed out". The other half of the same event is in the device
/// log for that run:
///
/// `WebPageProxy::didFailProvisionalLoadForFrame … isMainFrame=1,
/// domain=WebKitErrorDomain, code=102`
///
/// which is WebKit's `FrameLoadInterruptedByPolicyChange` — our own delegate
/// cancelling the main frame — and the next statement in the delegate handed the
/// URL to the system. One rule, two symptoms.
///
/// ## Why "is this a link they tapped?" cannot be answered here
///
/// It looks answerable, and it is the reason the allow list seemed reasonable: a
/// listener tapping a blog post mid-sign-in meant to read it. But a sign-in *is* a
/// chain of `http(s)` hops we do not own, and nothing in a `WKNavigationAction`
/// says whether this one is the next step of the transaction or a footer link. A
/// rule that guesses wrong towards "leave the app" ends the sign-in and gives the
/// session away; a rule that guesses wrong the other way keeps the listener in
/// place, on a page they can go back from, with a line telling them they have left
/// Google's sign-in. Only one of those is a failure the app can recover from.
///
/// Upstream needs none of this because it has none of the problem: its
/// `WebViewClient` overrides `onPageFinished` and nothing else — no
/// `shouldOverrideUrlLoading` — because Android's `WebView` has no "open this
/// elsewhere" affordance to intercept. Every URL loads in place there too, which
/// is the rule this file now states.
///
/// ## What is still refused, and why it is not the same problem
///
/// Every scheme that is not `http(s)`, because WebKit hands those to the system by
/// itself whether we ask it to or not. That is what stops `youtube://` and
/// `itms-apps://` from opening another app and taking the session with it — and
/// unlike `open`, refusing them is a decision we own.
enum SignInNavigation {

    /// A prefix match also accepts music.youtube.com.evil.test. Only the real
    /// HTTPS origin may expose a profile or supply the captured page scope.
    static func isMusicOrigin(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == "music.youtube.com"
            && (url?.port == nil || url?.port == 443)
            && url?.user == nil && url?.password == nil
    }

    enum Refusal: Equatable {
        /// Not a web page. WebKit would hand it to another app.
        case notAWebPage
        /// No scheme, or no host to read. Refused rather than allowed, because
        /// "I do not know where this goes" is how a policy becomes decorative.
        case unusable

        /// What the listener is told, in one place so the wording cannot drift from
        /// the rule it is describing.
        var summary: String {
            switch self {
            case .notAWebPage:
                return "That link opens another app. It is blocked, so your sign-in keeps its place here."
            case .unusable:
                return "That link could not be read, so it is blocked."
            }
        }
    }

    enum Decision: Equatable {
        /// Load it in the sign-in web view.
        case load
        /// Cancel it, and say why. Nothing is opened anywhere else.
        case refuse(Refusal)
    }

    static func decision(for url: URL?) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse(.unusable) }
        // Read before the host: a `youtube://` URL is refused on its scheme, and a
        // hostname that happens to look like Google's cannot argue it into the
        // load path. That ordering is the whole difference between the two.
        guard scheme == "https" || scheme == "http" else { return .refuse(.notAWebPage) }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refuse(.unusable) }
        return .load
    }

    /// The hosts Google's own sign-in is made of.
    ///
    /// Read on a dot-delimited suffix, so `accounts.google.co.uk` matches and
    /// `accounts.google.com.evil.test` does not — the dot is the entire difference
    /// between those two, and a `contains` check would accept the second.
    ///
    /// ## Not part of the decision above
    ///
    /// This answers a different question — *should the listener be told they have
    /// wandered off* — and it is kept separate so the navigation rule cannot
    /// quietly start depending on it again. The sign-in works on hosts not in this
    /// list; the list only says which pages are the sign-in proper.
    static let signInDomains = [
        "google.com",
        "googleapis.com",
        "gstatic.com",
        "youtube.com",
        "ytimg.com",
    ]

    /// Whether a page belongs to Google's sign-in, for the footer line that says so.
    static func isSignInHost(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url?.host?.lowercased(), !host.isEmpty
        else { return false }
        return signInDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The line shown when the page is somewhere else.
    ///
    /// It names the host, because that is the only part the listener can check
    /// against their own address bar, and "you have left Google's sign-in" with no
    /// way to see where they went is the "flicker and nothing happened" failure
    /// [Refusal.summary] exists to avoid.
    static func offSignInHostAdvice(host: String?) -> String {
        guard let host, !host.isEmpty else { return "This page is not part of Google's sign-in." }
        return "**\(host)** is not part of Google's sign-in. Go back to keep signing in."
    }
}

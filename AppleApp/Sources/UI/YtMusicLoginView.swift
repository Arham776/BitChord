import SwiftUI
import WebKit
import BitChordShared

/// In-app Google sign-in for YouTube Music — port of upstream
/// `auth/YtMusicLoginScreen.kt`.
///
/// ## Flow
///
/// Load Google's real login with `continue=music.youtube.com`. The user
/// authenticates against accounts.google.com (2FA, passkeys, etc.). When Google
/// redirects to music.youtube.com the session cookies land in an isolated
/// `WKWebsiteDataStore` (not Safari, not `URLSession.shared`), and the listener
/// presses **Continue** to take them. The password never passes through app code.
///
/// Do not replace this with `ASWebAuthenticationSession`: that uses Safari and
/// never returns a music.youtube.com cookie jar to the app.
///
/// ## Why the listener presses Continue
///
/// Upstream does not capture on reaching the Music origin either, and the reason
/// is the whole design of this screen: a multi-account login can still be waiting
/// for the listener to choose an identity *on that very page*, and capturing the
/// moment it loads is the race that used to create a fake profile and close too
/// soon. So arriving only *enables* the button, and a refused capture leaves the
/// button there rather than closing on a session that is not a session yet.
///
/// ## Why the navigation is policed
///
/// A music.youtube.com page carries links out to the YouTube Music app and to the
/// App Store, and WebKit hands a `youtube://` or `itms-apps://` navigation to the
/// system by itself — which takes the listener out of the sign-in into another app
/// mid-flow, and the session never comes back. So those are refused here, and
/// *nothing* on this screen is ever opened anywhere else: see [SignInNavigation]
/// for why the rest of the web loads in place instead.
@Observable
final class LoginFlow {
    /// The page has reached the Music origin, so there may be a session to take.
    var reachedMusicOrigin = false
    /// A capture is in flight.
    var taking = false
    /// The newest refusal, if the last thing that happened was a refused link.
    var refusal: SignInNavigation.Refusal?
    /// The host of a page that is not Google's sign-in, or nil while it is.
    var offOriginHost: String?
    /// A capture the listener asked for that had no session to take.
    var captureNote: String?

    /// Where the Continue button reaches the web view.
    ///
    /// A plain box rather than observable state on purpose. It is written from
    /// `makeWebView`, which runs *during* the view update, and SwiftUI discards
    /// observable mutations made there — which is how Continue ends up wired to a
    /// web view the button cannot see, and pressing it does nothing at all. Held
    /// outside observation the write survives, and the button reads it when it is
    /// tapped rather than trusting a re-render to have happened in between.
    let session = SignInSession()

    /// Whether the Continue button should be offered at all.
    ///
    /// Only once the page is on the origin: a button that does nothing on the
    /// Google page is worse than no button, because it looks like the sign-in is
    /// broken rather than incomplete.
    var canTake: Bool { reachedMusicOrigin && !taking }

    /// The one line under the web view: the newest thing worth saying, or nothing.
    ///
    /// Derived rather than assigned, so a refusal cannot be left standing over a
    /// message the listener needs, and the "you have wandered off the sign-in"
    /// line cannot outlive the page that caused it. Ordered by freshness: what the
    /// listener just did beats what they just pressed, and the standing "you are
    /// off the sign-in" warning is the oldest of the three.
    var message: String? {
        if let captureNote { return captureNote }
        if let refusal { return refusal.summary }
        if let offOriginHost { return SignInNavigation.offSignInHostAdvice(host: offOriginHost) }
        return nil
    }
}

/// The one thing the Continue button has to be able to call. See [LoginFlow.session].
final class SignInSession {
    var take: (() -> Void)?
}

struct YtMusicLoginView: View {
    var onCookiesCaptured: (String) -> Void

    @State private var flow = LoginFlow()

    var body: some View {
        VStack(spacing: 0) {
            LoginWebView(
                flow: flow,
                onCookiesCaptured: onCookiesCaptured,
                onUnavailable: { reason in flow.captureNote = reason }
            )

            footer
        }
    }

    /// The Continue control, and whatever is worth saying above it.
    ///
    /// A real button rather than a capture on navigation, because a capture on
    /// navigation is the race described above — and because "I signed in and it
    /// did not take" is almost always this: the page had not settled on an
    /// identity yet, and a refused capture says so instead of storing something
    /// that will read as signed out tomorrow.
    private var footer: some View {
        VStack(spacing: 8) {
            if let message = flow.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
            }
            Button {
                flow.captureNote = nil
                flow.refusal = nil
                flow.session.take?()
            } label: {
                if flow.taking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Continue").font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!flow.canTake)
            .accessibilityHint(
                flow.reachedMusicOrigin
                    ? "Finishes the sign-in and saves the session to this device"
                    : "Available once Google has signed you in"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(.bar)
    }
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let flow: LoginFlow
    var onCookiesCaptured: (String) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCookiesCaptured: onCookiesCaptured,
            onUnavailable: onUnavailable
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    let flow: LoginFlow
    var onCookiesCaptured: (String) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCookiesCaptured: onCookiesCaptured,
            onUnavailable: onUnavailable
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Conformed to `WKHTTPCookieStoreObserver` only so it can be registered and
/// unregistered; the observer callback is not used. Nothing is captured from it —
/// the listener presses Continue — and it only matters that the store is
/// registered, so that the jar is written to the store the harvest reads.
///
/// `@MainActor` because every navigation delegate callback WebKit makes is made on
/// the main thread, and because [flow] is observed SwiftUI state: the cookie-store
/// completion handlers are the only thing here that is not, and those hop to the
/// main actor themselves rather than mutating observed state off it.
@MainActor
final class LoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let flow: LoginFlow
    private let onCookiesCaptured: (String) -> Void
    private let onUnavailable: (String) -> Void
    /// `nonisolated` so `deinit` can reach it.
    ///
    /// `deinit` runs on whichever thread released the coordinator, so it cannot
    /// touch main-actor state. Unregistering from the cookie store is the one
    /// thing it has to do, and reaching it through
    /// `MainActor.assumeIsolated` would *trap* rather than merely leave an
    /// observer registered — a crash on the way out, over a leak that ends with
    /// the store itself.
    nonisolated private let store = WKWebsiteDataStore.nonPersistent()
    private var captured = false
    /// Weak, because the coordinator is the navigation delegate the web view
    /// retains, and a strong reference back would be a cycle.
    private weak var webView: WKWebView?

    init(
        flow: LoginFlow,
        onCookiesCaptured: @escaping (String) -> Void,
        onUnavailable: @escaping (String) -> Void
    ) {
        self.flow = flow
        self.onCookiesCaptured = onCookiesCaptured
        self.onUnavailable = onUnavailable
    }

    deinit {
        // Safe without an actor hop: see `store`.
        store.httpCookieStore.remove(self)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // Deliberately empty. Registering is the point; observing is not. Nothing
        // is captured from here — a cookie changing is not a settled identity.
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Google's own refusal of embedded web views: on iOS WebKit sends a
        // *mobile* agent, and `accounts.google.com` answers that with "This
        // browser or app may not be secure" before the password is ever typed.
        // Upstream hits none of this because Android's `WebView` is a system
        // browser Google allowlists, and it sets no agent of its own.
        //
        // `applicationNameForUserAgent` would only *append* to the engine's agent,
        // leaving the mobile one in front, so the whole string is replaced. See
        // `SignInUserAgent` for why this is the shape it is and why
        // `ASWebAuthenticationSession` is not the answer.
        config.applicationNameForUserAgent = nil
        let webView = WKWebView(frame: .zero, configuration: config)
        if SignInUserAgent.needsReplacing(defaultAgent: webView.customUserAgent ?? "") {
            webView.customUserAgent = SignInUserAgent.desktopSafari()
        }
        // A window that opens itself is how a `youtube://` link gets followed from
        // inside a page. The navigation policy below is the real guard; this is
        // the one that stops the page even asking.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        store.httpCookieStore.add(self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        // How the Continue button reaches the session. Set here rather than
        // handed back to the view as state — see [LoginFlow.session].
        flow.session.take = { [weak self] in self?.takeSession() }
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    // ---- what the login page is allowed to do ------------------------------

    /// What to do with a navigation, given where it points.
    ///
    /// A thin re-export of [SignInNavigation.decision] rather than a rule of its
    /// own, so the one place the rule is written is also the one place it is
    /// checked. A second copy here would be a second answer to the same question,
    /// and the one that shipped is the one nobody would remember to update.
    static func navigationDecision(for url: URL?) -> SignInNavigation.Decision {
        SignInNavigation.decision(for: url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        // A nil target frame is a new window, which is `createWebViewWith`'s to
        // answer; only a real main frame is "where the sign-in is now".
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        switch Self.navigationDecision(for: url) {
        case .load:
            decisionHandler(.allow)
            announce(url, isMainFrame: isMainFrame)
        case .refuse(let why):
            // Cancelled, and *only* cancelled. There is no branch here that hands
            // a URL to the system: following one is what opened the YouTube Music
            // app and lost the sign-in, and the only way to be sure that cannot
            // happen again is for the capability not to exist on this screen.
            decisionHandler(.cancel)
            NSLog("[BitChord] sign-in refused a navigation to \(url?.absoluteString ?? "?")")
            flow.refusal = why
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A `target="_blank"` link, decided exactly as any other navigation.
        // Loading it unconditionally is how a `youtube://` link in a new window
        // got followed.
        let url = navigationAction.request.url
        switch Self.navigationDecision(for: url) {
        case .load:
            if let url { webView.load(URLRequest(url: url)) }
        case .refuse(let why):
            NSLog("[BitChord] sign-in refused a new-window navigation to \(url?.absoluteString ?? "?")")
            flow.refusal = why
        }
        return nil
    }

    /// Says where the listener is, whenever the main frame stops being the sign-in.
    ///
    /// Every `http(s)` page loads here, so the sign-in survives a hop to a host
    /// nobody enumerated — but a listener who has genuinely left Google's sign-in
    /// should be able to see that rather than infer it from a page they did not
    /// ask for. Only the main frame counts: Google's own pages load iframes, and
    /// a line of text about an ad server is noise.
    private func announce(_ url: URL?, isMainFrame: Bool) {
        guard isMainFrame else { return }
        let onSignIn = SignInNavigation.isSignInHost(url)
        flow.offOriginHost = onSignIn ? nil : url?.host?.lowercased()
        // A refused link is newer news than the page it was on.
        if onSignIn { flow.refusal = nil }
    }

    // ---- the state the button reads ----------------------------------------

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Re-checked on every navigation rather than latched: a listener who
        // wanders off the origin must lose the button, or they can press it
        // against a page that is no longer signed in.
        let onOrigin = webView.url?.absoluteString.hasPrefix(Self.musicOrigin) ?? false
        flow.reachedMusicOrigin = onOrigin
        // The cookie store commits after `didFinish`, so the first press would
        // otherwise race it. Warmed, not awaited — the listener decides when, and
        // by then the jar has long since settled.
        store.httpCookieStore.getAllCookies { _ in }
    }

    // ---- taking the session -------------------------------------------------

    /// The `ytcfg` check is upstream's and it is not decoration. A login in
    /// progress has *already* been given a SAPISID by the time the password is
    /// typed, so a jar that merely has a signing secret in it is evidence of
    /// nothing — and storing one of those is how a sign-in appears to succeed and
    /// then reports signed out on the next launch. `LOGGED_IN` on the page is the
    /// claim that the identity has settled.
    private func takeSession() {
        guard !captured, !flow.taking else { return }
        guard flow.reachedMusicOrigin else {
            flow.captureNote = "Finish signing in on the Google page first."
            return
        }
        flow.taking = true
        flow.refusal = nil
        flow.captureNote = nil
        let view = webView
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            let header = Self.cookieHeader(cookies)
            Task { @MainActor in
                guard let self, let view else { return }
                guard AuthBridge.shared.hasApiSid(cookieHeader: header) else {
                    self.finish(message: "Google has not issued a session yet.")
                    return
                }
                view.evaluateJavaScript(Self.ytcfgProbe) { raw, _ in
                    Task { @MainActor in
                        guard Self.isSignedInConfig(raw) else {
                            // Upstream logs this and leaves the screen open. So does
                            // this: the listener can press again once the page has
                            // settled.
                            self.finish(message: "Still choosing an account on the Google page — try again in a moment.")
                            return
                        }
                        self.finish(header: header)
                    }
                }
            }
        }
    }

    private func finish(header: String? = nil, message: String? = nil) {
        flow.taking = false
        if let header {
            // Flushed before the session is handed over, for the reason upstream
            // gives: a cookie jar written after the screen closes is a jar the
            // *next* sign-in reads instead of this one. It is the difference
            // between signing in and appearing to.
            store.httpCookieStore.getAllCookies { _ in }
            captured = true
            onCookiesCaptured(header)
        } else if let message {
            onUnavailable(message)
        }
    }

    /// Upstream's `YTCFG_PROBE`, unchanged in substance: `ytcfg` is the page's
    /// own account configuration, and `LOGGED_IN` is the only claim on it that
    /// means an identity has settled.
    private static let ytcfgProbe = """
    (function () {
      try {
        if (!window.ytcfg || !window.ytcfg.get) return null;
        return { loggedIn: String(!!window.ytcfg.get('LOGGED_IN')) };
      } catch (e) {
        return null;
      }
    })()
    """

    private static func isSignedInConfig(_ raw: Any?) -> Bool {
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return object["loggedIn"] as? String == "true"
    }

    /// Upstream `CookieManager.getCookie(MUSIC_ORIGIN)`: only cookies the browser
    /// would send to music.youtube.com. Mixing a `.google.com` SID with YouTube's
    /// SAPISID is a different account than the Music one.
    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        guard let url = URL(string: musicOrigin + "/") else { return "" }
        return cookies
            .filter { wouldSend($0, to: url) }
            .filter { !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func wouldSend(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        if let expiry = cookie.expiresDate, expiry < Date() { return false }
        let domain = cookie.domain.lowercased()
        let hostOnly = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let hostMatch = host == hostOnly || host.hasSuffix("." + hostOnly)
        guard hostMatch else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path.hasPrefix(cookiePath)
    }

    private static let musicOrigin = "https://music.youtube.com"
    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin" +
        "?ltmpl=music&service=youtube&passive=true" +
        "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )!
}

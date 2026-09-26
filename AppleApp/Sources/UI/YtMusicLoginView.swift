import SwiftUI
import WebKit
import BitChordShared

/// In-app Google sign-in for YouTube Music — port of upstream
/// `auth/YtMusicLoginScreen.kt` plus the confirmation header in `MainActivity.kt`.
///
/// ## Flow
///
/// Load Google's real login with `continue=music.youtube.com`. The user
/// authenticates against accounts.google.com (2FA, passkeys, etc.). When Google
/// redirects to music.youtube.com the session cookies land in an isolated
/// `WKWebsiteDataStore` (not Safari, not `URLSession.shared`), and the listener
/// confirms the profile shown by the live page. The password never passes through
/// app code.
///
/// Do not replace this with `ASWebAuthenticationSession`: that uses Safari and
/// never returns a music.youtube.com cookie jar to the app.
///
/// ## Why the listener confirms rather than the page capturing
///
/// Upstream does not capture on reaching the Music origin either, and the reason
/// is the whole design of this screen: a multi-account login can still be waiting
/// for the listener to choose an identity *on that very page*, and capturing the
/// moment it loads is the race that used to create a fake profile and close too
/// soon. So arriving only *enables* confirmation, and a refused capture leaves the
/// screen open rather than closing on a session that is not a session yet.
///
/// ## Why the navigation is policed
///
/// A music.youtube.com page carries links out to the YouTube Music app and to the
/// App Store, and WebKit hands a `youtube://` or `itms-apps://` navigation to the
/// system by itself — which takes the listener out of the sign-in into another app
/// mid-flow, and the session never comes back. So those are refused here, and
/// *nothing* on this screen is ever opened anywhere else: see [SignInNavigation]
/// for why the rest of the web loads in place instead.
///
/// ## The header is upstream's
///
/// Title, hint and confirmation live in the navigation bar — Close, the "switch
/// using the avatar" hint once the Music page is up, and Use This Profile — which
/// is both what upstream's `MainActivity` shows and what a sheet is expected to
/// look like on this platform. There is deliberately no bottom Continue button: a
/// confirmation that lives in the bar cannot be missed below a page that scrolls,
/// and it is where Cancel already lives.
struct YtMusicLoginView: View {
    /// The confirmed session, with a completion the owner calls once validation
    /// finishes. Staying open until then is the point: closing on capture and
    /// validating afterwards is how a half-finished channel chooser used to
    /// become a durable broken account.
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onDismiss: () -> Void

    @State private var flow = LoginFlow()

    var body: some View {
        LoginWebView(
            flow: flow,
            onCaptured: onCaptured,
            onUnavailable: { reason in flow.captureFailed(reason) }
        )
        .navigationTitle("Sign in to YouTube Music")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onDismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                if flow.taking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking…")
                } else if flow.pageReady {
                    Button("Use This Profile") {
                        flow.session.take?()
                    }
                    .accessibilityHint("Saves the profile shown by the page to this device")
                }
            }
        }
        .overlay(alignment: .top) {
            // Upstream's subtitle under the title: what to do once the Music page
            // is up, or that there is nothing to take yet after a failed attempt.
            // A banner over the page rather than a footer under it, so it reads
            // against the profile it describes instead of below a page that may
            // have scrolled it out of sight.
            if let prompt = flow.prompt {
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(flow.captureFailedMessage == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .transition(.opacity)
            }
        }
    }
}

@Observable
final class LoginFlow {
    /// The page has reached the Music origin, so there may be a session to take.
    var reachedMusicOrigin = false
    /// A capture is in flight.
    var taking = false
    /// The last capture was asked for and there was no session to take.
    var captureFailedMessage: String?
    /// The newest refusal, if the last thing that happened was a refused link.
    var refusal: SignInNavigation.Refusal?
    /// The host of a page that is not Google's sign-in, or nil while it is.
    var offOriginHost: String?

    /// Where the confirmation button reaches the web view.
    ///
    /// A plain box rather than observable state on purpose. It is written from
    /// `makeWebView`, which runs *during* the view update, and SwiftUI discards
    /// observable mutations made there — which is how confirmation ends up wired
    /// to a web view the button cannot see, and pressing it does nothing at all.
    /// Held outside observation the write survives, and the button reads it when
    /// it is tapped rather than trusting a re-render to have happened in between.
    let session = SignInSession()

    /// Upstream's `onPageReady`: the Music page is up, so the confirmation is
    /// offered. A button anywhere before that is worse than no button, because it
    /// looks like the sign-in is broken rather than incomplete.
    var pageReady: Bool { reachedMusicOrigin && !taking }

    /// A capture was asked for and there was no session to take. Not a failure
    /// and not a reason to close: the screen stays open and the listener can try
    /// again once the page has settled.
    func captureFailed(_ reason: String) {
        taking = false
        captureFailedMessage = reason
    }

    func captureSucceeded() {
        taking = false
        captureFailedMessage = nil
    }

    /// The one line over the page: the newest thing worth saying, or nothing.
    ///
    /// Ordered by freshness: a failed capture is what the listener just did, a
    /// refused link is what they just pressed, and the standing guidance is the
    /// oldest of the three. The avatar-switch hint only appears once the Music
    /// page is up — before that there is no profile to switch.
    var prompt: String? {
        if let captureFailedMessage { return captureFailedMessage }
        if let refusal { return refusal.summary }
        if reachedMusicOrigin {
            return "Switch using the avatar, then use this profile."
        }
        if let offOriginHost { return SignInNavigation.offSignInHostAdvice(host: offOriginHost) }
        return nil
    }
}

/// The one thing the confirmation button has to be able to call. See [LoginFlow.session].
final class SignInSession {
    var take: (() -> Void)?
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let flow: LoginFlow
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCaptured: onCaptured,
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
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCaptured: onCaptured,
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
/// the listener confirms — and it only matters that the store is registered, so
/// that the jar is written to the store the harvest reads.
///
/// `@MainActor` because every navigation delegate callback WebKit makes is made on
/// the main thread, and because [flow] is observed SwiftUI state: the cookie-store
/// completion handlers are the only thing here that is not, and those hop to the
/// main actor themselves rather than mutating observed state off it.
@MainActor
final class LoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let flow: LoginFlow
    private let onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
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
        onCaptured: @escaping (SignInCapture, @escaping (Bool) -> Void) -> Void,
        onUnavailable: @escaping (String) -> Void
    ) {
        self.flow = flow
        self.onCaptured = onCaptured
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
        // How the confirmation button reaches the session. Set here rather than
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
            noteMainFrame(url, isMainFrame: isMainFrame)
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
            noteMainFrame(url, isMainFrame: true)
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
    ///
    /// Done here as well as in `didFinish` because the Music page is reached by a
    /// redirect chain whose intermediate steps are the navigations, and waiting
    /// for the final commit to notice the origin is waiting for news already in
    /// hand. `didFinish` still re-checks, so wandering off the origin takes the
    /// confirmation away even when the leaving hop commits without a decision.
    private func noteMainFrame(_ url: URL?, isMainFrame: Bool) {
        guard isMainFrame, let url else { return }
        if url.absoluteString.hasPrefix(Self.musicOrigin) {
            flow.reachedMusicOrigin = true
        }
        let onSignIn = SignInNavigation.isSignInHost(url)
        flow.offOriginHost = onSignIn ? nil : url.host?.lowercased()
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
            flow.captureFailed("Finish signing in on the Google page first.")
            return
        }
        flow.taking = true
        flow.refusal = nil
        flow.captureFailedMessage = nil
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
                        guard let fields = SignInCapture.parse(jsResult: raw),
                              fields.loggedIn
                        else {
                            // Upstream logs this and leaves the screen open. So does
                            // this: the listener can try again once the page has
                            // settled, including after switching channels in the
                            // avatar menu.
                            self.finish(message: "No signed-in profile is available on this page yet.")
                            return
                        }
                        // A delegated identity is the most specific answer the live
                        // page can give. Otherwise normalise its DATASYNC_ID.
                        let dataSyncId = fields.pageId
                            ?? SignInCapture.normalizeDataSyncId(fields.dataSyncId)
                        self.captured = true
                        self.flow.captureSucceeded()
                        self.onCaptured(
                            SignInCapture(
                                cookie: header,
                                pageId: fields.pageId,
                                dataSyncId: dataSyncId,
                                authUser: fields.authUser,
                                visitorData: fields.visitorData,
                                clientVersion: fields.clientVersion,
                                loggedIn: true
                            )
                        ) { [weak self] accepted in
                            Task { @MainActor in
                                guard let self else { return }
                                if accepted {
                                    self.flow.captureSucceeded()
                                } else {
                                    // Validation refused it after the fact. The screen
                                    // stays open so the listener can try again; the
                                    // cookie stays stored so the next attempt has
                                    // something to be judged against.
                                    self.captured = false
                                    self.finish(message: "No signed-in profile is available on this page yet.")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(header: String? = nil, message: String? = nil) {
        // Kept for the refusal paths, which carry no session: the one line they
        // need is the reason, and the screen staying open is the behaviour.
        flow.taking = false
        if let message {
            onUnavailable(message)
        }
    }

    /// Upstream's `YTCFG_PROBE`, unchanged in substance: `ytcfg` is the page's
    /// own account configuration, and `LOGGED_IN` is the only claim on it that
    /// means an identity has settled. It returns an object rather than a string
    /// so the web view serialises it — a probe that stringified its own result
    /// would come back double-encoded on Android.
    private static let ytcfgProbe = """
    (function () {
      try {
        if (!window.ytcfg || !window.ytcfg.get) return null;
        var get = function (key) {
          var value = window.ytcfg.get(key);
          return (value === undefined || value === null || value === '') ? null : String(value);
        };
        return {
          loggedIn: String(!!window.ytcfg.get('LOGGED_IN')),
          pageId: get('DELEGATED_SESSION_ID'),
          dataSyncId: get('DATASYNC_ID'),
          authUser: get('SESSION_INDEX'),
          visitorData: get('VISITOR_DATA'),
          clientVersion: get('INNERTUBE_CLIENT_VERSION')
        };
      } catch (e) {
        return null;
      }
    })()
    """

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

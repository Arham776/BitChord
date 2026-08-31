import SwiftUI
import WebKit
import BitChordShared

/// In-app Google sign-in for YouTube Music — port of upstream
/// `auth/YtMusicLoginScreen.kt`.
///
/// Flow: load Google's real login with `continue=music.youtube.com`. The
/// user authenticates against accounts.google.com (2FA, passkeys, etc.).
/// When Google redirects to music.youtube.com, session cookies land in an
/// isolated `WKWebsiteDataStore` (not Safari, not URLSession.shared). We
/// lift the Cookie header once it contains a SAPISID signing secret and
/// hand it to [onCookiesCaptured]. The password never passes through app
/// code.
///
/// Do not replace this with `ASWebAuthenticationSession`: that uses Safari
/// and never returns a music.youtube.com cookie jar to the app.
struct YtMusicLoginView: View {
    var onCookiesCaptured: (String) -> Void

    var body: some View {
        LoginWebView(onCookiesCaptured: onCookiesCaptured)
            .ignoresSafeArea(edges: .bottom)
    }
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    var onCookiesCaptured: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(onCookiesCaptured: onCookiesCaptured)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    var onCookiesCaptured: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(onCookiesCaptured: onCookiesCaptured)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

final class LoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let onCookiesCaptured: (String) -> Void
    private let store = WKWebsiteDataStore.nonPersistent()
    private var captured = false
    private var lastURL: URL?
    private var harvestWork: DispatchWorkItem?

    init(onCookiesCaptured: @escaping (String) -> Void) {
        self.onCookiesCaptured = onCookiesCaptured
    }

    deinit {
        store.httpCookieStore.remove(self)
        harvestWork?.cancel()
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        store.httpCookieStore.add(self)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleHarvest(from: webView.url)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        scheduleHarvest(from: lastURL)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// Android's `CookieManager.getCookie` is complete at `onPageFinished`.
    /// WKWebView commits cookies after `didFinish`, so wait a beat and also
    /// harvest on `cookiesDidChange`.
    private func scheduleHarvest(from url: URL?) {
        if let url { lastURL = url }
        guard !captured, let url = lastURL, url.absoluteString.hasPrefix(Self.musicOrigin) else { return }
        harvestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.harvest() }
        harvestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func harvest() {
        guard !captured else { return }
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.captured else { return }
            let header = Self.cookieHeader(cookies)
            guard AuthBridge.shared.hasApiSid(cookieHeader: header) else { return }
            self.captured = true
            DispatchQueue.main.async {
                self.onCookiesCaptured(header)
            }
        }
    }

    /// Upstream `CookieManager.getCookie(MUSIC_ORIGIN)`: only cookies the
    /// browser would send to music.youtube.com. Mixing `.google.com` SID
    /// with YouTube's SAPISID is a different account than the Music one.
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

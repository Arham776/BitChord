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

final class LoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let onCookiesCaptured: (String) -> Void
    private let store = WKWebsiteDataStore.nonPersistent()
    private var captured = false

    init(onCookiesCaptured: @escaping (String) -> Void) {
        self.onCookiesCaptured = onCookiesCaptured
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tryCapture(from: webView.url)
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

    private func tryCapture(from url: URL?) {
        guard !captured, let url, url.absoluteString.hasPrefix(Self.musicOrigin) else { return }
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

    /// Cookies Google would send to music.youtube.com — parent-domain
    /// `.google.com` / `.youtube.com` included. Names and values only;
    /// never logged.
    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain.contains("youtube.com") || domain.contains("google.com")
            }
            .filter { !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static let musicOrigin = "https://music.youtube.com"
    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin" +
        "?ltmpl=music&service=youtube&passive=true" +
        "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )!
}

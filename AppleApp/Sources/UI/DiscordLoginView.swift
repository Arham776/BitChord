import SwiftUI
import WebKit
import BitChordShared

/// Captures a Discord user token the same unofficial way upstream's Kizzy login does.
struct DiscordLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in to Discord. BitChord reads the token Discord stores locally — never your password."
    @State private var username: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                DiscordWebView { token in
                    DiscordBridge.shared.validateToken(token: token, callback: TokenAdapter { ok, name in
                        Task { @MainActor in
                            if ok {
                                username = name
                                status = "Signed in as \(name ?? "Discord")"
                                DiscordGateway.shared.connect(token: token)
                            } else {
                                status = "Token rejected."
                            }
                        }
                    })
                }
            }
            .navigationTitle("Discord")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if username != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }
}

#if os(macOS)
private struct DiscordWebView: NSViewRepresentable {
    var onToken: (String) -> Void
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scrape(webView)
        }
        func scrape(_ webView: WKWebView) {
            webView.evaluateJavaScript("(webpackChunkdiscord_app.push([[''],{},e=>{m=[];for(let c in e.c)m.push(e.c[c])}]),m).find(m=>m?.exports?.default?.getToken!==void 0).exports.default.getToken()") { result, _ in
                if let token = result as? String, token.count > 20 {
                    self.onToken(token)
                }
            }
            webView.evaluateJavaScript("window.localStorage.getItem('token')") { result, _ in
                if let raw = result as? String {
                    let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if token.count > 20 { self.onToken(token) }
                }
            }
        }
    }
}
#else
private struct DiscordWebView: UIViewRepresentable {
    var onToken: (String) -> Void
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.localStorage.getItem('token')") { result, _ in
                if let raw = result as? String {
                    let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if token.count > 20 { self.onToken(token) }
                }
            }
        }
    }
}
#endif

private final class TokenAdapter: DiscordBridgeTokenCallback {
    let handler: (Bool, String?) -> Void
    init(_ handler: @escaping (Bool, String?) -> Void) { self.handler = handler }
    func onResult(ok: Bool, username: String?) { handler(ok, username) }
}

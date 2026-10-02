import Foundation
import WebKit
import BitChordShared

/// Upstream's BotGuard fallback, isolated from the signed-in browser and cookies.
@MainActor
final class ApplePoTokenProvider: NSObject, PlaybackTokenBridgeProvider, WKNavigationDelegate {
    static let shared = ApplePoTokenProvider()
    static var solverURL: URL?
    private var web: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?
    private var bootstrap: Task<String, Error>?
    private var context = ""
    private var expires = Date.distantPast
    private enum Failure: Error { case unavailable }

    nonisolated func generate(videoId: String, visitorData: String, callback: any PlaybackTokenBridgeTokenCallback) {
        Task { @MainActor in
            let result = Completion(callback)
            let work = Task {
                do {
                    let streaming = try await self.prepare(visitor: visitorData)
                    let player = try await self.mint(videoId)
                    result.finish(player, streaming)
                } catch { result.finish(nil, nil) }
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if result.finish(nil, nil) { work.cancel() }
            }
        }
    }

    private final class Completion {
        private var callback: (any PlaybackTokenBridgeTokenCallback)?
        init(_ callback: any PlaybackTokenBridgeTokenCallback) { self.callback = callback }
        @discardableResult func finish(_ player: String?, _ streaming: String?) -> Bool {
            guard let callback else { return false }
            self.callback = nil
            callback.onResult(playerToken: player, streamingToken: streaming)
            return true
        }
    }

    private func prepare(visitor: String) async throws -> String {
        let key = "\(Innertube.shared.sessionGeneration):\(visitor)"
        if key == context, Date() < expires, let bootstrap { return try await bootstrap.value }
        bootstrap?.cancel()
        loading?.resume(throwing: Failure.unavailable)
        loading = nil
        web?.stopLoading()
        web = nil
        context = key
        let task = Task { @MainActor in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let rule = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "BitChord-Playback-Verification-No-Network",
                encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]")
            if let rule { config.userContentController.add(rule) }
            let view = WKWebView(frame: .zero, configuration: config)
            view.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"
            view.navigationDelegate = self
            self.web = view
            guard let url = Self.solverURL ?? Bundle.main.url(forResource: "po_token", withExtension: "html", subdirectory: "YouTubeSolver"),
                  let html = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unavailable }
            try await withCheckedThrowingContinuation { continuation in
                self.loading = continuation
                view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
            }
            let challenge = try Self.parseChallenge(await self.challenge(nil))
            let answer = try await self.js("window.bitChordSignal = await runBotGuard(challenge); return window.bitChordSignal.botguardResponse;", arguments: ["challenge": challenge], view: view)
            guard let response = answer as? String else { throw Failure.unavailable }
            let integrity = try await self.challenge(response)
            guard let values = try JSONSerialization.jsonObject(with: Data(integrity.utf8)) as? [Any], values.count >= 2,
                  let encoded = values[0] as? String, let bytes = Self.decodeBase64(encoded), let ttl = values[1] as? NSNumber else { throw Failure.unavailable }
            _ = try await self.js("await createPoTokenMinter(window.bitChordSignal.webPoSignalOutput, new Uint8Array(bytes)); return true;", arguments: ["bytes": Array(bytes)], view: view)
            guard self.context == key else { throw CancellationError() }
            self.expires = Date().addingTimeInterval(max(0, ttl.doubleValue - 600))
            return try await self.mint(visitor, view: view)
        }
        bootstrap = task
        do { return try await task.value }
        catch { if context == key { expires = .distantPast; bootstrap = nil }; throw error }
    }

    private func challenge(_ response: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            PlaybackTokenBridge.shared.challenge(botguardResponse: response, callback: ChallengeReply(continuation))
        }
    }
    private final class ChallengeReply: NSObject, PlaybackTokenBridgeChallengeCallback {
        let continuation: CheckedContinuation<String, Error>
        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
        func onResult(json: String?, message: String?) {
            if let json { continuation.resume(returning: json) }
            else { continuation.resume(throwing: Failure.unavailable) }
        }
    }
    private func js(_ script: String, arguments: [String: Any], view: WKWebView) async throws -> Any? {
        try Task.checkCancellation()
        return try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }
    private func mint(_ identifier: String, view: WKWebView? = nil) async throws -> String {
        guard let view = view ?? web else { throw Failure.unavailable }
        let output = try await js("return Array.from(await obtainPoToken(new Uint8Array(bytes)));", arguments: ["bytes": Array(identifier.utf8)], view: view)
        guard let numbers = output as? [NSNumber], !numbers.isEmpty,
              numbers.allSatisfy({ (0...255).contains($0.intValue) }) else { throw Failure.unavailable }
        return Data(numbers.map { $0.uint8Value }).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    static func decodeBase64(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
    static func parseChallenge(_ raw: String) throws -> [String: Any] {
        guard let outer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any] else { throw Failure.unavailable }
        let values: [Any]
        if outer.count > 1, let encoded = outer[1] as? String, let bytes = decodeBase64(encoded) {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(bytes.map { $0 &+ 97 })) as? [Any] else { throw Failure.unavailable }
            values = decoded
        } else {
            guard let first = outer.first as? [Any] else { throw Failure.unavailable }
            values = first
        }
        guard values.count > 7, let program = values[4] as? String, let global = values[5] as? String,
              let script = (values[1] as? [Any])?.first(where: { $0 is String }) as? String else { throw Failure.unavailable }
        return ["messageId": values[0], "interpreterHash": values[3], "program": program, "globalName": global,
                "clientExperimentsStateBlob": values[7], "interpreterJavascript": ["privateDoNotAccessOrElseSafeScriptWrappedValue": script]]
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        loading?.resume(); loading = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(webView) }
    private func failed(_ view: WKWebView) {
        guard view === web else { return }
        expires = .distantPast
        loading?.resume(throwing: Failure.unavailable); loading = nil
    }
}

@MainActor
enum ApplePoTokenWiring {
    static func install() { PlaybackTokenBridge.shared.register(provider: ApplePoTokenProvider.shared) }
}

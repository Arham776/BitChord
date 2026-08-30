import Foundation
import JavaScriptCore
import BitChordShared

/// YouTube player-JS: signatureTimestamp, signatureCipher unlock, and `n`-param
/// transform. Mirrors NewPipe YoutubeSignatureUtils via JSContext.
actor YouTubePlayerJs {
    static let shared = YouTubePlayerJs()

    private var baseJsUrl: String?
    private var baseJsText: String?
    private var cachedSts: Int?
    private var deobfuscationScript: String?

    func signatureTimestamp() async throws -> Int {
        if let cachedSts { return cachedSts }
        let js = try await baseJs()
        guard let match = js.range(of: #"signatureTimestamp[=:](\d+)"#, options: .regularExpression) else {
            throw PlayerJsError("signatureTimestamp not found in base.js")
        }
        let digits = String(js[match]).filter(\.isNumber)
        guard let sts = Int(digits) else { throw PlayerJsError("bad sts") }
        cachedSts = sts
        print("[PlayerJs] signatureTimestamp=\(sts)")
        return sts
    }

    /// Unlock `signatureCipher` → playable URL, then transform `n` if present.
    func unlockCipher(_ cipher: String, videoId: String) async throws -> String {
        let params = Self.parseQuery(cipher)
        guard let base = params["url"], let signature = params["s"] else {
            throw PlayerJsError("signatureCipher missing url/s")
        }
        let into = params["sp"] ?? "signature"
        let solved = try await deobfuscateSignature(signature)
        let sep = base.contains("?") ? "&" : "?"
        let withSig = "\(base)\(sep)\(into)=\(Self.percentEncode(solved))"
        return await deobfuscateN(url: withSig, videoId: videoId)
    }

    func deobfuscateN(url: String, videoId: String) async -> String {
        guard var comps = URLComponents(string: url),
              let items = comps.queryItems,
              let nItem = items.first(where: { $0.name == "n" }),
              let nValue = nItem.value, !nValue.isEmpty
        else { return url }

        do {
            let js = try await baseJs()
            let funcName = try extractNFunctionName(js: js)
            let transformed = try runNamedFunction(js: js, funcName: funcName, arg: nValue)
            comps.queryItems = items.map {
                $0.name == "n" ? URLQueryItem(name: "n", value: transformed) : $0
            }
            let out = comps.url?.absoluteString ?? url
            if out != url {
                print("[PlayerJs] n \(nValue.prefix(8))… -> \(transformed.prefix(8))… for \(videoId)")
            }
            return out
        } catch {
            print("[PlayerJs] n-param failed for \(videoId): \(error)")
            return url
        }
    }

    // MARK: - Signature

    private func deobfuscateSignature(_ signature: String) async throws -> String {
        let script = try await deobfuscationCode()
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exc in
            print("[PlayerJs] JS exception: \(exc?.toString() ?? "?")")
        }
        ctx.evaluateScript(script)
        guard let fn = ctx.objectForKeyedSubscript("deobfuscate") else {
            throw PlayerJsError("deobfuscate() missing after eval")
        }
        guard let result = fn.call(withArguments: [signature])?.toString(), !result.isEmpty else {
            throw PlayerJsError("deobfuscate returned empty")
        }
        return result
    }

    private func deobfuscationCode() async throws -> String {
        if let deobfuscationScript { return deobfuscationScript }
        let js = try await baseJs()
        let (funcName, extraArgs) = try findSigFunction(js: js)
        let funcBody = try extractFunction(js: js, name: funcName)
        let helperName = try findHelperObjectName(in: funcBody)
        let helper = try extractHelperObject(js: js, name: helperName)
        let globalArr = extractGlobalArray(js: js)
        let caller = "function deobfuscate(a){return \(funcName)(\(extraArgs)a);}"
        let script = [globalArr, helper, funcBody, caller]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ";\n")
        deobfuscationScript = script
        print("[PlayerJs] built sig deobfuscator (\(funcName))")
        return script
    }

    private func findSigFunction(js: String) throws -> (String, String) {
        let patterns = [
            #"\b(?:[a-zA-Z0-9_$]+)&&\((?:[a-zA-Z0-9_$]+)=([a-zA-Z0-9_$]{2,})\((\d+,)decodeURIComponent\((?:[a-zA-Z0-9_$]+)\)\)"#,
            #"\b(?:[a-zA-Z0-9_$]+)&&\((?:[a-zA-Z0-9_$]+)=([a-zA-Z0-9_$]{2,})\(decodeURIComponent\((?:[a-zA-Z0-9_$]+)\)\)"#,
            #"\bm=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(h\.s\)\)"#,
            #"\bc&&\(c=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(c\)\)"#,
            #"(?:\b|[^a-zA-Z0-9$])([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*\"\"\s*\)"#,
            #"([\w$]+)\s*=\s*function\((\w+)\)\{\s*\2=\s*\2\.split\(\"\"\)\s*;"#,
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let m = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: js) {
                let name = String(js[r])
                var extra = ""
                if m.numberOfRanges > 2, let r2 = Range(m.range(at: 2), in: js) {
                    extra = String(js[r2])
                }
                return (name, extra)
            }
        }
        throw PlayerJsError("sig function not found")
    }

    private func extractFunction(js: String, name: String) throws -> String {
        let marker = "\(name)=function"
        guard let start = js.range(of: marker)?.lowerBound else {
            throw PlayerJsError("function \(name) not found")
        }
        guard let open = js[start...].firstIndex(of: "{") else {
            throw PlayerJsError("function \(name) has no body")
        }
        var depth = 0
        var i = open
        while i < js.endIndex {
            let c = js[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    return "var " + String(js[start..<js.index(after: i)])
                }
            }
            i = js.index(after: i)
        }
        throw PlayerJsError("unbalanced braces in \(name)")
    }

    private func findHelperObjectName(in funcBody: String) throws -> String {
        let pat = #"[;,]([A-Za-z0-9_$]{2,})\.\w+\("#
        if let regex = try? NSRegularExpression(pattern: pat),
           let m = regex.firstMatch(in: funcBody, range: NSRange(funcBody.startIndex..., in: funcBody)),
           m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: funcBody) {
            return String(funcBody[r])
        }
        throw PlayerJsError("helper object name not found")
    }

    private func extractHelperObject(js: String, name: String) throws -> String {
        let marker = "var \(name)={"
        if let start = js.range(of: marker)?.lowerBound {
            return try braceSlice(js, from: start, prefix: "")
        }
        let alt = "\(name)={"
        guard let s2 = js.range(of: alt)?.lowerBound else {
            throw PlayerJsError("helper \(name) not found")
        }
        return try braceSlice(js, from: s2, prefix: "var ")
    }

    private func braceSlice(_ js: String, from start: String.Index, prefix: String) throws -> String {
        guard let open = js[start...].firstIndex(of: "{") else {
            throw PlayerJsError("helper has no body")
        }
        var depth = 0
        var i = open
        while i < js.endIndex {
            let c = js[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    var end = js.index(after: i)
                    if end < js.endIndex && js[end] == ";" {
                        end = js.index(after: end)
                    }
                    return prefix + String(js[start..<end])
                }
            }
            i = js.index(after: i)
        }
        throw PlayerJsError("unbalanced helper braces")
    }

    private func extractGlobalArray(js: String) -> String? {
        let pat = #"var [A-z]=['\"].*?['\"]\.split\(\"[;{]\"\)"#
        guard let regex = try? NSRegularExpression(pattern: pat),
              let m = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let r = Range(m.range, in: js) else { return nil }
        return String(js[r])
    }

    // MARK: - n-param

    private func extractNFunctionName(js: String) throws -> String {
        if let setRange = js.range(of: ".set(\"n\"") ?? js.range(of: ".set('n'") {
            let before = String(js[js.startIndex..<setRange.lowerBound].suffix(800))
            let pat = #"([a-zA-Z0-9\$_]+)\s*\(\s*a[^)]*\.get\(\"n\"\)"#
            if let regex = try? NSRegularExpression(pattern: pat),
               let m = regex.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: before) {
                return String(before[r])
            }
        }
        let fallback = #"([a-zA-Z0-9\$_]+)\s*=\s*function\([^)]*\)\s*\{[^\}]*split\(\"\"\).*join\(\"\"\).*"#
        if let regex = try? NSRegularExpression(pattern: fallback, options: [.dotMatchesLineSeparators]),
           let m = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: js) {
            return String(js[r])
        }
        throw PlayerJsError("n function not found")
    }

    private func runNamedFunction(js: String, funcName: String, arg: String) throws -> String {
        let ctx = JSContext()!
        if let r = js.range(of: funcName) {
            let start = js.index(r.lowerBound, offsetBy: -5000, limitedBy: js.startIndex) ?? js.startIndex
            let end = js.index(r.lowerBound, offsetBy: 30000, limitedBy: js.endIndex) ?? js.endIndex
            ctx.evaluateScript(String(js[start..<end]))
        }
        if ctx.objectForKeyedSubscript(funcName) == nil {
            ctx.evaluateScript(js)
        }
        guard let fn = ctx.objectForKeyedSubscript(funcName) else {
            throw PlayerJsError("function \(funcName) not in context")
        }
        guard let result = fn.call(withArguments: [arg])?.toString(), !result.isEmpty else {
            throw PlayerJsError("\(funcName) returned empty")
        }
        return result
    }

    // MARK: - base.js

    private func baseJs() async throws -> String {
        if let t = baseJsText { return t }
        let url = try await baseJsUrlString()
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PlayerJsError("empty base.js")
        }
        baseJsText = text
        return text
    }

    private func baseJsUrlString() async throws -> String {
        if let u = baseJsUrl { return u }
        if let fromIframe = try? await playerUrlFromIframeApi() {
            baseJsUrl = fromIframe
            return fromIframe
        }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=dummy")!)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""
        if let range = html.range(of: #""jsUrl":"[^"]*base\.js[^"]*""#, options: .regularExpression) {
            var js = String(html[range])
            js = js.replacingOccurrences(of: "\"jsUrl\":\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\\/", with: "/")
            let full = js.hasPrefix("https://") ? js : "https://www.youtube.com\(js)"
            baseJsUrl = full
            return full
        }
        throw PlayerJsError("jsUrl not found")
    }

    private func playerUrlFromIframeApi() async throws -> String {
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "https://www.youtube.com/iframe_api")!)
        let text = String(data: data, encoding: .utf8) ?? ""
        let pat = #"player\\?/([a-z0-9]{8})\\?/"#
        guard let regex = try? NSRegularExpression(pattern: pat),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            throw PlayerJsError("iframe_api hash not found")
        }
        let hash = String(text[r])
        return "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_GB/base.js"
    }

    private static func parseQuery(_ cipher: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in cipher.split(separator: "&") {
            let bits = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { continue }
            out[bits[0].removingPercentEncoding ?? bits[0]] =
                bits[1].removingPercentEncoding ?? bits[1]
        }
        return out
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    struct PlayerJsError: Error, LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }
}

// MARK: - CipherUnlockBridge wiring

enum CipherUnlockWiring {
    static func install() {
        CipherUnlockBridge.shared.setImpl(value: Impl())
    }

    private final class Impl: CipherUnlockBridgeImpl {
        func signatureTimestamp(callback: CipherUnlockBridgeResultCallback) {
            Task {
                do {
                    let sts = try await YouTubePlayerJs.shared.signatureTimestamp()
                    callback.onResult(value: String(sts), error: nil)
                } catch {
                    callback.onResult(value: nil, error: error.localizedDescription)
                }
            }
        }

        func unlockCipher(videoId: String, cipher: String, callback: CipherUnlockBridgeResultCallback) {
            Task {
                do {
                    let url = try await YouTubePlayerJs.shared.unlockCipher(cipher, videoId: videoId)
                    callback.onResult(value: url, error: nil)
                } catch {
                    callback.onResult(value: nil, error: error.localizedDescription)
                }
            }
        }
    }
}

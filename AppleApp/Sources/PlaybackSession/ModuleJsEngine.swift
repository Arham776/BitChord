import Foundation
import JavaScriptCore
import BitChordShared

/// JavaScriptCore engine for the legacy module protocol, registered as
/// `ModuleEngine.Impl` at launch.
///
/// ## Why this is not a one-shot evaluator
///
/// Module scripts routinely set up state at load time — an eager token fetch, a
/// negotiated session — and expect it to be there for the *next* call. The
/// previous host built a fresh `JSContext` per call, so `searchTracks()` and
/// `getTrackStreamUrl()` each ran in their own throwaway VM and nothing a module
/// set up in one was visible in the other. Every such module failed on the
/// second call, silently. Upstream fixed this by keeping one engine alive per
/// loaded module; that is what [Pool] is.
///
/// ## Why a pool and not one engine per module
///
/// A JS interpreter is single-threaded and a module's own HTTP calls happen
/// *inside* it, holding it for their whole duration — measured upstream at 7.7s
/// for one module on one query. One engine at a time is correct but serialises a
/// fan-out across every module in the index, which is the common case. Each
/// module gets [enginesPerModule] engines, grown lazily, so a module nobody is
/// hammering costs exactly one and a download queue is not stuck behind a search.
///
/// ## Threading
///
/// A `JSContext` is not thread-safe, so each engine owns a private serial queue
/// and is only ever touched from it. That is what makes the blocking `fetch`
/// bridge below safe: it parks the engine's own queue, not a shared one, so a
/// slow module cannot stall a fast one.
final class ModuleJsEngine: NSObject, ModuleEngineImpl {
    static let shared = ModuleJsEngine()

    /// How many modules stay resident.
    ///
    /// Has to cover a whole index, not a working set: a search fans out to every
    /// module at once, so a cap below the index size means each search evicts
    /// engines that same search is still using.
    private static let maxModules = 12

    /// How many callers one module can serve at once.
    ///
    /// Sized against the download queue's own width: enough that workers are not
    /// queueing behind each other on the one slow module in an index, few enough
    /// that a three-module index is nine interpreters and not thirty.
    private static let enginesPerModule = 3

    /// `searchTracks(query, limit, context)`.
    private static let searchLimit = 50

    private static let requestTimeout: TimeInterval = 20

    // MARK: - Pools

    private final class Pool {
        let scriptUrl: String
        let fetchBase: String
        let script: String
        let lock = NSCondition()
        /// Every engine made, for teardown — including ones currently in use.
        var made: [Engine] = []
        /// The ones nobody is inside right now.
        var free: [Engine] = []
        /// Engines made or being made. The claim that stops two callers both growing.
        var started = 0
        /// Monotonic stamp for LRU eviction; the lowest is the coldest.
        var lastUsed: UInt64 = 0

        init(scriptUrl: String, fetchBase: String, script: String) {
            self.scriptUrl = scriptUrl
            self.fetchBase = fetchBase
            self.script = script
        }
    }

    /// One interpreter, on its own queue.
    private final class Engine {
        let queue: DispatchQueue
        let context: JSContext

        init(moduleId: String, script: String, fetchBase: String) {
            queue = DispatchQueue(
                label: "app.bitchord.BitChord.module.\(moduleId).\(UUID().uuidString)"
            )
            guard let context = JSContext() else {
                // `JSContext()` has no failure path on Apple platforms, but the
                // type is optional, so say so rather than force-unwrapping.
                fatalError("JavaScriptCore refused to create a context")
            }
            self.context = context
            context.exceptionHandler = { context, exception in
                // Swallowing these is how a module fails in silence. Log them.
                DebugLog.shared.d(
                    message: "module JS threw: \(exception?.toString() ?? "unknown") "
                        + "at \(context?.description ?? "unknown")"
                )
            }
            ModuleJsEngine.prepare(context, moduleId: moduleId, script: script, fetchBase: fetchBase)
        }
    }

    private let poolsLock = NSLock()
    private var pools: [String: Pool] = [:]
    private var clock: UInt64 = 0

    // MARK: - ModuleEngineImpl

    func search(
        moduleId: String,
        scriptUrl: String,
        query: String,
        tier: String?,
        callback: ModuleEngineRowsCallback
    ) {
        answer(
            moduleId: moduleId, scriptUrl: scriptUrl, export: "searchTracks",
            args: [Self.quote(query), String(Self.searchLimit), Self.contextArg(tier: tier)]
        ) { json, error in
            callback.onResult(json: json, error: error)
        }
    }

    func stream(
        moduleId: String,
        scriptUrl: String,
        trackId: String,
        tier: String?,
        callback: ModuleEngineStreamCallback
    ) {
        // The tier goes in the second argument *and* in the settings, because
        // modules read it from whichever they were written against:
        // `getTrackStreamUrl(id, preferredQuality, context)` takes the argument,
        // while the multi-source ones prefer `context.settings.quality.value` and
        // treat the argument as a fallback. Sending only one left the
        // better-featured modules on their own default, which is how a request
        // for lossless arrived at the server as no request at all.
        answer(
            moduleId: moduleId, scriptUrl: scriptUrl, export: "getTrackStreamUrl",
            args: [Self.quote(trackId), Self.quote(Self.moduleQuality(tier)), Self.contextArg(tier: tier)]
        ) { json, error in
            callback.onResult(json: json, error: error)
        }
    }

    // MARK: - Entry point

    private func answer(
        moduleId: String,
        scriptUrl: String,
        export: String,
        args: [String],
        then: @escaping @Sendable (String?, String?) -> Void
    ) {
        let trimmed = scriptUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            then(nil, "module \(moduleId) has no script URL")
            return
        }

        // Already loaded: hand out an engine without touching the network.
        if let pool = existingPool(moduleId) {
            serve(moduleId: moduleId, pool: pool, export: export, args: args, then: then)
            return
        }
        // Cold. The download is the slow part and it must not hold an engine
        // slot, so it happens before anything is claimed.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let script = try? await Self.downloadScript(trimmed) else {
                then(nil, "could not download the script for \(moduleId)")
                return
            }
            guard let pool = self.loadPool(moduleId: moduleId, scriptUrl: trimmed, script: script)
            else { return }
            self.serve(moduleId: moduleId, pool: pool, export: export, args: args, then: then)
        }
    }

    private func serve(
        moduleId: String,
        pool: Pool,
        export: String,
        args: [String],
        then: @escaping @Sendable (String?, String?) -> Void
    ) {
        guard let engine = acquire(moduleId: moduleId, pool: pool) else {
            then(nil, "no engine available for \(moduleId)")
            return
        }
        // `sync`, not `async`: the module's own work happens *inside* the
        // interpreter — including its HTTP — so there is nothing to overlap with
        // and an async hop would only add a suspension the caller cannot cancel.
        var result: (String?, String?) = (nil, "no answer")
        engine.queue.sync { result = ModuleJsEngine.callOn(engine.context, export: export, args: args) }
        release(engine, pool: pool)

        // A `{ error: … }` envelope is a module-level refusal, not a crash, and
        // the portable layer can say something better about it than "null".
        if let json = result.0, let refusal = Self.envelopeError(json) {
            then(nil, refusal)
            return
        }
        then(result.0, result.1)
    }

    /// Run one export and read its answer back.
    ///
    /// Two evaluations, because a `JSValue` holding a Promise stringifies to
    /// `"[object Promise]"` rather than resolving. The first drives the call
    /// inside an async IIFE that parks the result in a global; the second reads
    /// it. Every `await` in the chain resolves synchronously — that is what the
    /// blocking `fetch` bridge is *for* — so by the time the first evaluation
    /// returns the answer is already parked.
    private static func callOn(
        _ context: JSContext, export: String, args: [String]
    ) -> (String?, String?) {
        let kind = context.evaluateScript("typeof __bch_mod['\(export)']")
        guard kind?.toString() == "function" else {
            return (nil, "\(export) is not a function on this module")
        }
        context.evaluateScript("""
        var __bch_resolved_json = undefined;
        (async function() {
            var __fn = __bch_mod['\(export)'];
            if (!__fn) { __bch_resolved_json = JSON.stringify({error: 'not found'}); return; }
            try {
                var r = await __fn(\(args.joined(separator: ",")));
                __bch_resolved_json = typeof r === 'string' ? r : JSON.stringify(r);
            } catch(e) {
                __bch_resolved_json = JSON.stringify({ error: (e && e.message) ? e.message : String(e) });
            }
        })();
        """)
        return (readAnswer(context), nil)
    }

    /// The parked answer, pumping the job queue if it is not there yet.
    ///
    /// A module that used a genuine timer — or that offloaded work to a microtask
    /// chain longer than one tick — has not finished when the first evaluation
    /// returns. Bounded, so a module that never resolves costs a fixed wait
    /// rather than hanging the caller.
    private static func readAnswer(_ context: JSContext) -> String? {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let value = context.evaluateScript(
                "typeof __bch_resolved_json !== 'undefined' ? __bch_resolved_json : undefined"
            )
            if let text = value?.toString(), text != "undefined" { return text }
            if Date() >= deadline { return nil }
            // Evaluating anything drains JavaScriptCore's job queue, which is
            // where a pending promise continuation lives.
            _ = context.evaluateScript("void 0")
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func envelopeError(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String, !error.isEmpty,
              // Only a bare envelope counts. A module that answers with rows that
              // happen to carry an `error` field is answering, not refusing.
              object.count <= 2
        else { return nil }
        return error
    }

    // MARK: - Pool management

    private func existingPool(_ moduleId: String) -> Pool? {
        poolsLock.lock()
        clock &+= 1
        let pool = pools[moduleId]
        if let pool { pool.lastUsed = clock }
        poolsLock.unlock()
        return pool
    }

    private func loadPool(moduleId: String, scriptUrl: String, script: String) -> Pool? {
        poolsLock.lock()
        clock &+= 1
        if let existing = pools[moduleId] {
            existing.lastUsed = clock
            poolsLock.unlock()
            return existing
        }
        while pools.count >= Self.maxModules,
              let coldest = pools.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key,
              let victim = pools.removeValue(forKey: coldest) {
            poolsLock.unlock()
            // Evict outside the lock: tearing an engine down touches its queue.
            Self.discard(victim)
            poolsLock.lock()
        }
        let pool = Pool(scriptUrl: scriptUrl, fetchBase: scriptUrl, script: script)
        pool.lastUsed = clock
        pools[moduleId] = pool
        poolsLock.unlock()
        return pool
    }

    private static func discard(_ pool: Pool) {
        pool.lock.lock()
        let engines = pool.made
        pool.made.removeAll()
        pool.free.removeAll()
        pool.started = 0
        pool.lock.unlock()
        for engine in engines {
            // Releasing the context is what drops the host bindings; there is
            // no name list to walk and nothing downstream still holds it.
            engine.queue.sync { engine.context.exceptionHandler = nil }
        }
    }

    private func acquire(moduleId: String, pool: Pool) -> Engine? {
        pool.lock.lock()
        if let engine = pool.free.popLast() {
            pool.lock.unlock()
            return engine
        }
        let claimed = pool.started < Self.enginesPerModule
        if claimed { pool.started += 1 }
        pool.lock.unlock()

        if claimed {
            let engine = Engine(
                moduleId: moduleId, script: pool.script, fetchBase: pool.fetchBase
            )
            pool.lock.lock()
            pool.made.append(engine)
            pool.lock.unlock()
            return engine
        }
        // Every engine is in use. Wait for one rather than refuse: a download
        // queue asking for a second copy of a track is not an error.
        pool.lock.lock()
        while pool.free.isEmpty { pool.lock.wait() }
        let engine = pool.free.popLast()
        pool.lock.unlock()
        return engine
    }

    private func release(_ engine: Engine, pool: Pool) {
        pool.lock.lock()
        pool.free.append(engine)
        pool.lock.signal()
        pool.lock.unlock()
    }

    // MARK: - Engine construction

    private struct ModuleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func downloadScript(_ url: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            SourceBridge.shared.downloadScript(url: url, callback: ScriptResult { body, message in
                if let body {
                    continuation.resume(returning: body)
                } else {
                    continuation.resume(
                        throwing: ModuleError(message: message ?? "script download failed")
                    )
                }
            })
        }
    }

    /// Evaluate a module's script into a fresh context, bindings and all.
    private static func prepare(
        _ context: JSContext, moduleId: String, script: String, fetchBase: String
    ) {
        bindConsole(context)
        bindHost(context, fetchBase: fetchBase)
        context.evaluateScript(polyfills)

        context.evaluateScript("""
        var __bch_init_error = null;
        var __bch_mod = (function() {
            try {
                var module = { exports: {} };
                var exports = module.exports;
                var self = {};
                \(preprocess(script))
                if (module.exports && (module.exports.searchTracks || module.exports.getTrackStreamUrl)) {
                    return module.exports;
                }
                return {};
            } catch(e) {
                __bch_init_error = (e && e.message) ? e.message : String(e);
                return {};
            }
        })();
        """)

        if let failure = context.evaluateScript("__bch_init_error")?.toString(),
           !failure.isEmpty, failure != "null", failure != "undefined" {
            DebugLog.shared.d(message: "module \(moduleId) init error: \(failure)")
        }
    }

    // MARK: - Bindings

    /// `console`, which JavaScriptCore does not provide.
    ///
    /// Without it a module that logs at load time throws a `TypeError` on the
    /// very first statement, and the whole script fails to evaluate.
    private static func bindConsole(_ context: JSContext) {
        for name in ["log", "info", "warn", "error", "debug"] {
            let sink: @convention(block) (String) -> Void = { message in
                DebugLog.shared.d(message: "[\(name)] \(message)")
            }
            context.setObject(sink, forKeyedSubscript: "__bch_console_\(name)" as NSString)
        }
        context.evaluateScript("""
        var console = {
            log: __bch_console_log, info: __bch_console_info, debug: __bch_console_debug,
            warn: __bch_console_warn, error: __bch_console_error
        };
        """)
    }

    /// `fetch`, `setTimeout`, `clearTimeout`, `btoa`, `atob`.
    ///
    /// The native calls are blocking, which is deliberate: a module's HTTP
    /// happens inside the interpreter, and the two-evaluation protocol above only
    /// works if nothing is left in flight when the first evaluation returns. The
    /// engine's queue is its own, so parking it parks only that module's other
    /// callers.
    private static func bindHost(_ context: JSContext, fetchBase: String) {
        let fetch: @convention(block) (String, String, String, String?) -> String = {
            rawUrl, method, headersJson, body in
            let (status, text) = perform(
                url: resolve(rawUrl, against: fetchBase),
                method: method, headersJson: headersJson, body: body
            )
            return "{\"status\":\(status),\"ok\":\(status >= 200 && status < 299),"
                + "\"body\":\(quote(text))}"
        }
        context.setObject(fetch, forKeyedSubscript: "__bch_fetch" as NSString)

        // Run the callback now, having actually waited. A module that sequences
        // work with `setTimeout` would otherwise have the callback fire long
        // after the answer was read.
        let timer: @convention(block) (String?, Int) -> Int = { callbackBody, milliseconds in
            let delay = max(0, milliseconds) / 1000
            if delay > 0 { Thread.sleep(forTimeInterval: min(TimeInterval(delay), 10)) }
            guard let callbackBody, !callbackBody.isEmpty else { return 0 }
            context.evaluateScript("(\(callbackBody))()")
            return 0
        }
        context.setObject(timer, forKeyedSubscript: "__bch_setTimeout" as NSString)

        let encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        context.setObject(encode, forKeyedSubscript: "__bch_btoa" as NSString)

        let decode: @convention(block) (String) -> String = { value in
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
        context.setObject(decode, forKeyedSubscript: "__bch_atob" as NSString)

        context.evaluateScript("""
        var btoa = __bch_btoa;
        var atob = __bch_atob;
        var clearTimeout = function() {};

        // A web-compatible surface over the native binding. `ok` and `status`
        // come from the real response: reporting `ok: true` unconditionally —
        // which the previous host did — makes a module parse a 403 error page as
        // a search result instead of refusing it.
        var fetch = async function(url, options) {
            var method = 'GET', headers = '{}', body = null;
            if (options) {
                method = options.method || 'GET';
                if (options.headers) {
                    headers = typeof options.headers === 'string'
                        ? options.headers
                        : (function() { try { return JSON.stringify(options.headers); } catch(e) { return '{}'; } })();
                }
                if (options.body !== undefined && options.body !== null) {
                    body = typeof options.body === 'string' ? options.body : JSON.stringify(options.body);
                }
                if (options.signal && options.signal.aborted) throw new Error('Aborted');
            }
            var raw = JSON.parse(await __bch_fetch(String(url), method, headers, body));
            var respBody = raw.body;
            var response = {
                ok: raw.ok,
                status: raw.status,
                statusText: raw.ok ? 'OK' : 'Error',
                url: String(url),
                json: function() {
                    try { return JSON.parse(respBody); }
                    catch(e) { throw new Error('Invalid JSON: ' + String(respBody).substring(0, 200)); }
                },
                text: function() { return respBody; },
                blob: function() { return respBody; },
                arrayBuffer: function() { throw new Error('Not implemented'); },
                clone: function() { return response; },
                headers: { get: function() { return null; } }
            };
            // `json()` and `text()` answer values, not promises: a module written
            // against this protocol awaits the response and then reads the body,
            // and a promise here reads as `[object Promise]` — a silent empty
            // result rather than a failure anyone would notice.
            return response;
        };

        var setTimeout = function(fn, ms) {
            return __bch_setTimeout(typeof fn === 'function' ? fn.toString() : null, ms || 0);
        };
        """)
    }

    private static func perform(
        url: String, method: String, headersJson: String, body: String?
    ) -> (Int, String) {
        guard let endpoint = URL(string: url) else { return (0, "") }
        let verb = method.uppercased()
        var request = URLRequest(url: endpoint)
        request.httpMethod = verb.isEmpty ? "GET" : verb
        request.timeoutInterval = requestTimeout

        var hasUserAgent = false
        if let data = headersJson.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in headers {
                guard let string = value as? String else { continue }
                request.setValue(string, forHTTPHeaderField: key)
                if key.lowercased() == "user-agent" { hasUserAgent = true }
            }
        }
        // Some module backends refuse a request with no UA, so send one rather
        // than letting the platform default stand.
        if !hasUserAgent {
            request.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        }
        if let body, !body.isEmpty {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(
                    "application/json; charset=utf-8", forHTTPHeaderField: "Content-Type"
                )
            }
        }

        // Synchronous by necessity: see [bindHost].
        var status = 0
        var text = ""
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            done.signal()
        }.resume()
        // Bound the wait rather than the fetch: on timeout the request is still
        // in flight, and blocking its caller forever helps nobody.
        _ = done.wait(timeout: .now() + requestTimeout + 5)
        return (status, text)
    }

    /// Module backends are third parties. They get their own cookie jar and are
    /// not handed the listener's account cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    // MARK: - Pre-processing

    /// Strip ES-module `export` keywords so the script runs inside an IIFE that
    /// gives it a CommonJS-style `module.exports`.
    ///
    /// Also unwraps the template-literal export format some sources use —
    /// ``export const x = `…actual JS…` `` — where the payload is not JavaScript
    /// at all until the backticks come off. Without this the previous host got a
    /// `SyntaxError` on the first `export` and every such module failed to load.
    private static func preprocess(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if let open = firstMatch(of: #"^export\s+const\s+\w+\s*=\s*`"#, in: trimmed),
           let close = closingBacktick(in: trimmed, from: open.upperBound) {
            return String(trimmed[close..<trimmed.endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var result = trimmed
        result = replacing(
            #"\bexport\s+default\s+(?=function|class|const|let|var|async)"#, in: result
        ) { $0.replacingOccurrences(of: "export default", with: "") }
        result = replacing(
            #"\bexport\s+(const|let|var|function|class|async)\b"#, in: result
        ) { $0.replacingOccurrences(of: "export", with: "") }
        return replacing(#"\bexport\s*\{[^}]*\}\s*;?"#, in: result) { _ in "" }
    }

    private static func firstMatch(
        of pattern: String, in text: String
    ) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        guard let match else { return nil }
        return Range(match.range, in: text)
    }

    private static func replacing(
        _ pattern: String, in text: String, with transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var cursor = text.startIndex
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) {
            match, _, _ in
            guard let match, let matched = Range(match.range, in: text) else { return }
            result += text[cursor..<matched.lowerBound]
            result += transform(String(text[matched]))
            cursor = matched.upperBound
        }
        return result + text[cursor...]
    }

    private static func closingBacktick(
        in text: String, from start: String.Index
    ) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex)
                    ?? text.endIndex
                continue
            }
            if text[index] == "`" { return index }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Argument marshalling

    /// A single JSON string literal, for splicing into a script.
    private static func quote(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value]))
            ?? Data(#"[""]"#.utf8)
        let array = String(data: data, encoding: .utf8) ?? #"[""]"#
        return String(array.dropFirst().dropLast())
    }

    /// `{settings:{"quality":{"value":"LOSSLESS"}}}`.
    ///
    /// The tier's *protocol* name, not the resolver's: modules were written
    /// against `LOSSLESS`/`HIGH`/`LOW` and read anything else as "no preference".
    private static func contextArg(tier: String?) -> String {
        let name = moduleQuality(tier)
        guard !name.isEmpty else { return "{settings:{}}" }
        return "{settings:{\"quality\":{\"value\":\(quote(name))}}}"
    }

    private static func moduleQuality(_ tier: String?) -> String {
        switch tier {
        case "LOSSLESS": return "LOSSLESS"
        case "HIGH", "BEST": return "HIGH"
        case "MEDIUM": return "LOW"
        default: return ""
        }
    }

    /// A module index may name its scripts relatively, so resolve against the
    /// index's own address.
    private static func resolve(_ url: String, against base: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard !base.isEmpty,
              let endpoint = URL(string: base),
              let scheme = endpoint.scheme,
              let host = endpoint.host
        else { return url }
        if url.hasPrefix("/") { return "\(scheme)://\(host)\(url)" }

        var directory = endpoint.path
        let looksLikeFile = directory.hasSuffix(".json") || directory.hasSuffix(".js")
        if looksLikeFile {
            directory = (directory as NSString).deletingLastPathComponent
        }
        if !directory.hasSuffix("/") { directory += "/" }
        return "\(scheme)://\(host)\(directory)\(url)"
    }

    // MARK: - Polyfills

    /// Only what JavaScriptCore is actually missing, and only behind a guard.
    ///
    /// `btoa`/`atob` are the exception that matters — module backends hand out
    /// Basic-auth headers, and without them a module throws on its first request.
    private static let polyfills = """
    if (typeof Object.assign !== 'function') {
        Object.assign = function(target) {
            if (target == null) throw new TypeError('Cannot convert undefined or null to object');
            var to = Object(target);
            for (var i = 1; i < arguments.length; i++) {
                var source = arguments[i];
                if (source != null) for (var key in source) {
                    if (Object.prototype.hasOwnProperty.call(source, key)) to[key] = source[key];
                }
            }
            return to;
        };
    }
    if (typeof AbortController === 'undefined') {
        var AbortController = function() { this.signal = { aborted: false }; };
        AbortController.prototype.abort = function() { this.signal.aborted = true; };
    }
    if (typeof URL === 'undefined') {
        var URL = function(url) {
            this.href = url;
            try {
                var m = String(url).match(/^https?:\\/\\/([^/]+)(\\/.*)?$/);
                if (m) { this.hostname = m[1]; this.pathname = m[2] || '/'; }
            } catch(e) {}
        };
    }
    """
}

// MARK: - Wiring

enum ModuleEngineWiring {
    static func install() {
        ModuleEngine.shared.setImpl(value: ModuleJsEngine.shared)
    }
}

/// The shared bridge's callback, which is a protocol rather than a closure.
private final class ScriptResult: SourceBridgeStreamCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

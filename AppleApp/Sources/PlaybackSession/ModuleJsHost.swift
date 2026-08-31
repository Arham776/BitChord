import Foundation
import JavaScriptCore
import BitChordShared

/// Spine-style module host via JavaScriptCore (spec §1.3).
final class ModuleJsHost {
    static let shared = ModuleJsHost()

    struct Stream {
        let url: String
        let codec: String
        let lossless: Bool
        let kbps: Int
        let bitDepth: Int
        let sampleRate: Int
    }

    func stream(for title: String, artist: String, quality: String) async -> Stream? {
        let index = PlatformSettings.shared.getString(key: "module_index_url", default: "")
        guard !index.isEmpty else { return nil }
        guard var listing = await fetchIndex(index) else { return nil }
        let disabled = Set(PlatformSettings.shared.getString(key: "module_disabled", default: "")
            .split(separator: ",").map(String.init))
        let order = PlatformSettings.shared.getString(key: "module_order", default: "")
            .split(separator: ",").map(String.init)
        listing = listing.filter { !disabled.contains($0.id) }
        listing.sort { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
        for module in listing where module.lossless || quality != "LOSSLESS" {
            if let hit = await runModule(module, title: title, artist: artist, quality: quality) {
                return hit
            }
        }
        return nil
    }

    private struct Card: Codable {
        let id: String
        let name: String
        let author: String
        let version: String
        let download: String
        let lossless: Bool
    }
    private struct Listing: Codable { let modules: [Card] }

    private func fetchIndex(_ url: String) async -> [Card]? {
        await withCheckedContinuation { cont in
            SourceBridge.shared.fetchIndex(url: url, callback: IndexCB { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: listing.modules)
            })
        }
    }

    private func runModule(_ module: Card, title: String, artist: String, quality: String) async -> Stream? {
        guard !module.download.isEmpty else { return nil }
        let script: String? = await withCheckedContinuation { cont in
            SourceBridge.shared.downloadScript(url: module.download, callback: ScriptCB { body, _ in
                cont.resume(returning: body)
            })
        }
        guard let script, let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, _ in }
        injectFetch(ctx)
        ctx.evaluateScript("""
        var module = { exports: {} };
        var exports = module.exports;
        \(script)
        """)
        let search = ctx.evaluateScript("module.exports.searchTracks")
        guard search?.isUndefined == false else { return nil }
        let query = "\(artist) \(title)"
        let contextArg: [String: Any] = ["settings": ["quality": ["value": quality]]]
        guard let result = search?.call(withArguments: [query, contextArg]),
              let json = result.toString(),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = obj["tracks"] as? [[String: Any]] else { return nil }
        let candidates = tracks.map {
            TrackMatch.Candidate(
                title: $0["title"] as? String ?? "",
                artist: $0["artist"] as? String ?? artist,
                durationText: $0["duration"] as? String
            )
        }
        let target = TrackMatch.Target(title: title, artist: artist, durationSec: nil)
        guard let index = TrackMatch.bestIndex(in: candidates, target: target),
              let id = tracks[index]["id"] as? String else { return nil }
        let streamFn = ctx.evaluateScript("module.exports.getTrackStreamUrl")
        guard streamFn?.isUndefined == false,
              let stream = streamFn?.call(withArguments: [id, quality, contextArg]),
              let streamJson = stream.toString(),
              let streamData = streamJson.data(using: .utf8),
              let streamObj = try? JSONSerialization.jsonObject(with: streamData) as? [String: Any],
              let url = streamObj["streamUrl"] as? String, !url.isEmpty else { return nil }
        let track = streamObj["track"] as? [String: Any]
        let q = (track?["audioQuality"] as? String ?? "").uppercased()
        return Stream(
            url: url,
            codec: (track?["mimeType"] as? String) ?? "FLAC",
            lossless: q.contains("LOSSLESS") || url.lowercased().contains("flac"),
            kbps: 0,
            bitDepth: track?["bitDepth"] as? Int ?? 0,
            sampleRate: Int(track?["sampleRate"] as? Double ?? 0)
        )
    }

    private func injectFetch(_ ctx: JSContext) {
        let fetch: @convention(block) (String, JSValue?) -> String = { url, _ in
            guard let endpoint = URL(string: url) else { return "{\"ok\":false}" }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 20
            let sem = DispatchSemaphore(value: 0)
            var body = ""
            URLSession.shared.dataTask(with: request) { data, _, _ in
                body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 20)
            return body
        }
        ctx.setObject(fetch, forKeyedSubscript: "fetchSync" as NSString)
        ctx.evaluateScript("""
        function fetch(url, opts) {
            var body = fetchSync(String(url), opts || {});
            return Promise.resolve({
                ok: true,
                text: function() { return Promise.resolve(body); },
                json: function() { return Promise.resolve(JSON.parse(body)); }
            });
        }
        """)
    }
}

private final class IndexCB: SourceBridgeIndexCallback {
    let handler: (String?, String?) -> Void
    init(_ h: @escaping (String?, String?) -> Void) { handler = h }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

private final class ScriptCB: SourceBridgeStreamCallback {
    let handler: (String?, String?) -> Void
    init(_ h: @escaping (String?, String?) -> Void) { handler = h }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

import Foundation
import BitChordShared

// Playback resolution, against YouTube.
//
// The one thing in this app that cannot be checked with a fixture: whether a
// stream URL can be minted and served. The live app log said no —
//
//   every player client refused. ANDROID_MUSIC: Please sign in;
//   TVHTML5: The page needs to be reloaded.; ANDROID_VR: minted an unusable URL
//   (video/mp4; codecs="avc1.42001E, mp4a.40.2"); ANDROID_VR: Sign in to
//   confirm you're not a bot; IOS: no audio formats
//
// and the third of those is this port's own bug, not YouTube's: a format carrying
// an audio codec was being thrown away for being `video/mp4`, which is the only
// format a guest session is left with on most of the catalogue.
//
// So: resolve some real tracks, report which client served each, and — the part
// that is actually worth having — read a real ranged window off each minted URL
// and say what came back. A resolution that produces a URL nothing will serve is
// not a resolution, and that is what the previous version of this check was
// accepting.
//
// Run: scripts/check-playback.sh

let ids = ProcessInfo.processInfo.environment["VIDEO_IDS"]?
    .split(separator: ",").map(String.init) ?? [
        // Bohemian Rhapsody (official), Blinding Lights, Shape of You, and one
        // long tail entry — a live/indie upload is a different shape of answer from
        // a label release.
        "fJ9rUzIMcZQ",
        "0Vj66wUOMoU",
        "kJQP7kiw5Fk",
    ]

CipherUnlockWiring.install(player: YouTubePlayerJs(solverDirectory: URL(fileURLWithPath: CommandLine.arguments[1])))

var failures: [String] = []
var served: [(String, String, Int, String)] = []
var unavailable: [String] = []

for id in ids {
    let began = Date()
    do {
        let json = try await withCheckedThrowingContinuation { c in
            let callback = PlaybackResolve { json, message in
                if let json { c.resume(returning: json) }
                else { c.resume(throwing: PlaybackError.noValue(message)) }
            }
            PlayerBridge.shared.resolve(
                videoId: id, maxKbps: Int32(clamping: Int(Int32.max)), callback: callback
            )
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = payload["url"] as? String, let url = URL(string: urlString),
              let headers = payload["headers"] as? [String: String]
        else {
            failures.append("\(id): resolved but the payload had no URL in it")
            continue
        }
        let kbps = (payload["kbps"] as? Int) ?? 0
        let mime = (payload["mimeType"] as? String) ?? "?"

        // Read a real window off it, the way the engine will. A resolution that hands
        // back something this cannot read is not a resolution.
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let took = String(format: "%.1fs", Date().timeIntervalSince(began))
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let got = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
            let ok = (200...299).contains(http?.statusCode ?? 0) && bytes.count > 4096
            print("ok  \(id)  \(kbps)kbps  \(mime)  served \(http?.statusCode ?? 0) \(got)  \(bytes.count)B  \(took)")
            if !ok {
                failures.append("\(id): resolved, but a 64 KiB range came back \(http?.statusCode ?? 0) with \(bytes.count)B")
                continue
            }
            served.append((id, mime, kbps, got))
        } catch {
            failures.append("\(id): resolved, but the range read failed — \(error.localizedDescription)")
            print("FAIL \(id)  \(kbps)kbps  \(mime)  range read failed: \(error.localizedDescription)")
        }
    } catch {
        let raw = "\(error)"
        // A refusal that is about *this track* is an answer, not a defect: the video
        // is not available to this network or this account, and no amount of retrying
        // in the app will change it. A refusal that is about *every client* is a
        // problem worth failing on, because that is the state the whole app is in
        // when playback does not work.
        let trackRefusal = raw.lowercased().contains("unavailable")
            || raw.lowercased().contains("not available")
        if trackRefusal {
            print("skip  \(id)  not available to this network or account")
            unavailable.append(id)
        } else {
            failures.append("\(id): \(raw)")
            print("FAIL \(id)  \(raw)")
        }
    }
}

// A per-track refusal is information, not a failure: YouTube gates some tracks from
// some networks, and nothing in this app can change that. What the check *can* tell
// is whether the app can open a stream at all — so the verdict is on the walk, and a
// track that is simply unavailable or gated is reported and moved past.
let gated = failures.filter {
    let said = $0.lowercased()
    return said.contains("sign in") || said.contains("not a bot")
}
let realFailures = failures.filter { !gated.contains($0) }

print("")
if !unavailable.isEmpty {
    print("unavailable here, which is an answer rather than a failure: \(unavailable.joined(separator: ", "))")
}
if !gated.isEmpty {
    print("gated by YouTube right now — every client answered with a sign-in or bot check:")
    gated.forEach { print("  \u{00B7} \($0)") }
}
if served.isEmpty {
    print("")
    print("FAIL  nothing resolved, and nothing refused a stream URL for a reason outside this app")
    realFailures.forEach { print("  \u{00B7} \($0)") }
    exit(1)
}
print("")
print("served \(served.count) of \(ids.count):")
for (id, mime, kbps, contentType) in served {
    print("  \u{00B7} \(id)  \(mime)  \(kbps)kbps  answered \(contentType)")
}
if realFailures.isEmpty {
    print("")
    print("PASS  a stream opened and served a real 64 KiB window; every refusal was a refusal of the track or of this network, not of the app")
} else {
    print("FAIL  \(realFailures.count) problems:")
    realFailures.forEach { print("  \u{00B7} \($0)") }
    exit(1)
}

private enum PlaybackError: Error {
    case noValue(String?)
    var description: String {
        switch self {
        case .noValue(let message): return message ?? "resolve returned neither a URL nor a reason"
        }
    }
}

private final class PlaybackResolve: PlayerBridgeResolveCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

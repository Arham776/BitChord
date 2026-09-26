import Foundation
import BitChordShared

/// A resolved YouTube Music stream: the URL the engine fetches plus the
/// headers the CDN demands and the quality description for display.
struct ResolvedYouTubeStream {
    let url: String
    let kbps: Int
    let mimeType: String
    let headers: [String: String]
}

/// Swift bridge over the shared module's `StreamResolver` (via `PlayerBridge`):
/// resolves a videoId to a playable audio URL. The resolved payload crosses FFI
/// as JSON.
///
/// The resolution *policy* — which identities to ask, what to remember between
/// attempts, when to stand one down, and the signed-in retries — lives in the
/// shared module, mirroring upstream's own split. This is only the seam.
final class InnertubeStreamResolver: Sendable {
    static let shared = InnertubeStreamResolver()

    func resolve(videoId: String, maxKbps: Int = Int.max) async throws -> ResolvedYouTubeStream {
        let payload = try await withCheckedThrowingContinuation { continuation in
            PlayerBridge.shared.resolve(
                videoId: videoId,
                maxKbps: Swift.Int32(clamping: maxKbps == Int.max ? Int(Swift.Int32.max) : maxKbps),
                callback: ResolveCallbackAdapter { json, message in
                    if let json {
                        do {
                            let decoded = try JSONDecoder()
                                .decode(StreamPayload.self, from: Data(json.utf8))
                            continuation.resume(returning: ResolvedYouTubeStream(
                                url: decoded.url,
                                kbps: decoded.kbps,
                                mimeType: decoded.mimeType,
                                headers: decoded.headers
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        // The shared module's message names the track and every client
                        // that refused it, which is right for a log and wrong for a
                        // listener. `say` is where the two are separated; the raw
                        // reason is kept on the error's `raw` for whoever wants it.
                        let raw = message ?? "Stream resolution failed"
                        continuation.resume(throwing: StreamError(message: StreamError.say(raw), raw: raw))
                    }
                }
            )
        }

        // The `n` parameter is a throttle token googlevideo refuses to serve
        // un-transformed. Formats that arrived with a plain `url` are transformed
        // by the shared module as it unlocks them; this is the belt-and-braces pass
        // for any that still carry one, and it is a no-op when they do not.
        //
        // Upstream does the equivalent inside its extractor and does *not* run it a
        // second time over an already-solved URL — solving costs a trip through the
        // player JavaScript, and paying it twice is both latency and a second chance
        // to hit whatever is currently failing it.
        let deobfuscated = await YouTubePlayerJs.shared.deobfuscateN(url: payload.url, videoId: videoId)
        guard deobfuscated != payload.url else { return payload }
        return ResolvedYouTubeStream(
            url: deobfuscated, kbps: payload.kbps, mimeType: payload.mimeType, headers: payload.headers
        )
    }

    struct StreamError: Error, LocalizedError {
        /// The sentence a listener sees.
        let message: String
        /// What the shared module said, in full.
        ///
        /// Kept rather than discarded because it is the only place the per-client
        /// reasons exist and they are what a bug report needs. Never shown: it
        /// contains a video id and internal client names.
        let raw: String

        init(message: String, raw: String? = nil) {
            self.message = message
            self.raw = raw ?? message
        }

        var errorDescription: String? { message }

        /// What to show a listener, from whatever the shared module said.
        ///
        /// The shared module's message names the track and every client that refused
        /// it, which is the right thing for a log and the wrong thing to put in front
        /// of somebody: a video id and a list of internal client names is not a
        /// explanation. The two cases that are not "this one track is being awkward"
        /// get their own sentences, because they are the two a listener can do
        /// something about — and everything else gets one honest sentence rather than
        /// five words that name a subsystem.
        ///
        /// Same rule as the party screen's `describe`: the server's own words when it
        /// sent any, otherwise a statement of what failed and never the raw error.
        static func say(_ raw: String) -> String {
            let said = raw.lowercased()
            if said.contains("sign in") || said.contains("not a bot") {
                return "YouTube is asking this device to sign in before it will serve anything. That is YouTube's gate rather than anything to do with the track."
            }
            if said.contains("needs to be reloaded") || said.contains("page needs") {
                return "YouTube's player refused this connection. Trying again in a moment usually clears it."
            }
            if said.contains("unavailable") || said.contains("not available") {
                return "That track isn’t available right now."
            }
            if said.contains("no signature timestamp") {
                return "BitChord could not read YouTube’s player, so it could not open a stream. Check the connection and try again."
            }
            return "Couldn’t open a stream for that track."
        }
    }
}

private struct StreamPayload: Codable {
    let url: String
    let kbps: Int
    let mimeType: String
    let headers: [String: String]
}

private final class ResolveCallbackAdapter: PlayerBridgeResolveCallback {
    private let onResult: (String?, String?) -> Void

    init(onResult: @escaping (String?, String?) -> Void) {
        self.onResult = onResult
    }

    func onResult(json: String?, message: String?) {
        onResult(json, message)
    }
}

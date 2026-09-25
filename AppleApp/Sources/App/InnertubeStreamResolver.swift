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
                        continuation.resume(throwing: StreamError(
                            message: message ?? "Stream resolution failed"))
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
        let message: String
        var errorDescription: String? { message }
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

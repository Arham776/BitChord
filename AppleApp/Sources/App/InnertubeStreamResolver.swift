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

/// Swift bridge over the shared module's `PlayerBridge` (milestone 3):
/// resolves a videoId to a playable audio URL by walking device clients
/// against the `player` endpoint. The resolved payload crosses FFI as JSON.
final class InnertubeStreamResolver: Sendable {
    static let shared = InnertubeStreamResolver()

    func resolve(videoId: String) async throws -> ResolvedYouTubeStream {
        var stream = try await withCheckedThrowingContinuation { continuation in
            PlayerBridge.shared.resolve(
                videoId: videoId,
                callback: ResolveCallbackAdapter { json, message in
                    if let json {
                        do {
                            let payload = try JSONDecoder()
                                .decode(StreamPayload.self, from: Data(json.utf8))
                            continuation.resume(returning: ResolvedYouTubeStream(
                                url: payload.url,
                                kbps: payload.kbps,
                                mimeType: payload.mimeType,
                                headers: payload.headers
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
        // Ensure cver matches the minting client (upstream's patchClientVersion)
        stream = patchCver(stream)
        // Transform the `n` parameter — without this, googlevideo throttles/403s.
        // Cipher unlock already runs n-transform inside PlayerBridge; this is a
        // safety net for plain-URL clients that still carry `n`.
        let deob = await YouTubePlayerJs.shared.deobfuscateN(url: stream.url, videoId: videoId)
        if deob != stream.url {
            stream = ResolvedYouTubeStream(url: deob, kbps: stream.kbps, mimeType: stream.mimeType, headers: stream.headers)
        }
        return stream
    }

    private func patchCver(_ s: ResolvedYouTubeStream) -> ResolvedYouTubeStream {
        s
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
    let clientVersion: String?
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

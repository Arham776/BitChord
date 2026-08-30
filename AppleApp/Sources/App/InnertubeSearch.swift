import Foundation
import BitChordShared

/// A YouTube Music search result row, decoded from the shared module's
/// serialized `Song` list (the bridge crosses FFI as JSON so Swift never
/// touches Kotlin collection types).
struct YouTubeSong: Codable, Identifiable, Hashable {
    let videoId: String
    let title: String
    let artist: String
    let thumbnailUrl: String?
    let durationText: String?
    let albumName: String?
    let isVideo: Bool?

    var id: String { videoId }
}

/// Swift bridge over the shared module's innertube search (milestone 2):
/// `SearchBridge` launches the suspend call on Kotlin's dispatcher and
/// answers exactly once on a background thread; this converts it to
/// async/await.
final class InnertubeSearch: Sendable {
    static let shared = InnertubeSearch()

    func search(_ term: String, scope: String) async throws -> [YouTubeSong] {
        try await withCheckedThrowingContinuation { continuation in
            SearchBridge.shared.search(
                query: term,
                scope: scope,
                callback: BridgeCallbackAdapter { json, message in
                    if let json {
                        do {
                            let songs = try JSONDecoder()
                                .decode([YouTubeSong].self, from: Data(json.utf8))
                            continuation.resume(returning: songs.filter { $0.isVideo != true })
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: SearchError(message: message ?? "search failed"))
                    }
                }
            )
        }
    }

    struct SearchError: Error { let message: String }
}

private final class BridgeCallbackAdapter: SearchBridgeSearchCallback {
    private let onResult: (String?, String?) -> Void

    init(onResult: @escaping (String?, String?) -> Void) {
        self.onResult = onResult
    }

    func onResult(json: String?, message: String?) {
        onResult(json, message)
    }
}

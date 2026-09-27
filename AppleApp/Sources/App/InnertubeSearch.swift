import Foundation
import BitChordShared

struct SearchHitDTO: Codable, Identifiable, Hashable {
    let kind: String
    let videoId: String?
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
    let durationText: String?
    let albumName: String?
    let browseId: String?
    let browseType: String?
    let artistId: String?
    let albumId: String?
    let isVideo: Bool?
    let setVideoId: String?

    var id: String { videoId ?? browseId ?? title }

    var isBrowse: Bool { kind == "browse" && browseId != nil }

    /// The row YouTube Music itself promoted, rather than one that merely sorted
    /// well.
    ///
    /// A separate case rather than a sort, because a promotion is Google's answer
    /// to "what did they mean" and re-deriving it by ranking would be showing our
    /// guess at one. It is also the only row that gets a heading above it.
    var isTopResult: Bool { kind == "top" }

    /// Whether this is a playable track, promoted or not.
    var isTrack: Bool { !isBrowse && videoId != nil }

    var resolvedArtist: String {
        guard let raw = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        if raw.caseInsensitiveCompare("Unknown artist") == .orderedSame {
            return ""
        }
        if raw.contains(" • ") {
            let segments = raw.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for seg in segments {
                let lower = seg.lowercased()
                if ["song", "video", "album", "single", "ep", "artist", "playlist"].contains(lower) {
                    continue
                }
                if seg.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil {
                    continue
                }
                if seg.caseInsensitiveCompare("Unknown artist") != .orderedSame {
                    return seg
                }
            }
        }
        return raw
    }

    func asEntry() -> QueueEntry {
        let artistName = resolvedArtist
        if let videoId, videoId.hasPrefix("saavn:") {
            return QueueEntry(
                id: videoId, title: title, artist: artistName, source: videoId,
                thumbnailUrl: thumbnailUrl, durationText: durationText, albumName: albumName,
                artworkData: nil, isLocal: false
            )
        }
        return QueueEntry.youtube(
            videoId: videoId ?? id,
            title: title,
            artist: artistName,
            thumbnailUrl: thumbnailUrl,
            durationText: durationText,
            albumName: albumName,
            artistId: artistId,
            albumId: albumId,
            setVideoId: setVideoId
        )
    }
}

final class InnertubeSearch: Sendable {
    static let shared = InnertubeSearch()

    func search(_ term: String, scope: String) async throws -> [SearchHitDTO] {
        try await withCheckedThrowingContinuation { continuation in
            SearchBridge.shared.search(
                query: term,
                scope: scope,
                callback: BridgeCallbackAdapter { json, message in
                    if let json {
                        do {
                            let hits = try JSONDecoder()
                                .decode([SearchHitDTO].self, from: Data(json.utf8))
                            continuation.resume(returning: hits)
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

    func suggestions(_ input: String) async -> [String] {
        await withCheckedContinuation { continuation in
            SuggestionsBridge.shared.suggest(input: input, callback: SuggestAdapter { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let list = try? JSONDecoder().decode([String].self, from: data) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: list)
            })
        }
    }

    struct SearchError: Error { let message: String }
}

private final class BridgeCallbackAdapter: SearchBridgeSearchCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

private final class SuggestAdapter: SuggestionsBridgeSuggestionsCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

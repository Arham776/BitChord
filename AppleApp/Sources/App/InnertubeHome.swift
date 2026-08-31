import Foundation
import BitChordShared

/// One shelf of the signed-out Home/Explore feeds, decoded from the shared
/// module's serialized `HomeFeed` (the bridge crosses FFI as JSON, same
/// contract as search).
struct FeedShelf: Decodable, Identifiable {
    let title: String
    let items: [ShelfCard]
    let subtitle: String?

    var id: String { title }

    enum CodingKeys: String, CodingKey { case title, items, subtitle }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        items = try c.decodeIfPresent([ShelfCard].self, forKey: .items) ?? []
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    }
    init(title: String, items: [ShelfCard], subtitle: String? = nil) {
        self.title = title; self.items = items; self.subtitle = subtitle
    }
}

struct YouTubeSong: Codable, Identifiable, Hashable {
    let videoId: String
    let title: String
    let artist: String
    let thumbnailUrl: String?
    let durationText: String?
    let artistId: String?
    let albumId: String?
    let albumName: String?
    let isVideo: Bool?
    let setVideoId: String?
    var id: String { videoId }
}

/// A shelf card: a track (videoId) or an album/playlist/artist (browseId).
struct ShelfCard: Decodable, Identifiable, Hashable {
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
    let videoId: String?
    let browseId: String?

    var id: String { videoId ?? browseId ?? title }

    enum CodingKeys: String, CodingKey { case title, subtitle, thumbnailUrl, videoId, browseId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        browseId = try c.decodeIfPresent(String.self, forKey: .browseId)
    }
    init(title: String, subtitle: String? = nil, thumbnailUrl: String? = nil, videoId: String? = nil, browseId: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.thumbnailUrl = thumbnailUrl; self.videoId = videoId; self.browseId = browseId
    }
}

private struct FeedPage: Decodable {
    let shelves: [FeedShelf]
    let continuation: String?
}



/// Swift bridge over the shared module's Home/Explore/library feeds
/// (upstream's `YtMusicRepository` browse pairing).
struct FeedResult {
    let shelves: [FeedShelf]
    let continuation: String?
}

final class InnertubeFeed: Sendable {
    static let shared = InnertubeFeed()

    func home() async throws -> FeedResult {
        try await fetch { HomeBridge.shared.home(callback: $0) }
    }

    func moreHome(token: String) async throws -> FeedResult {
        try await fetch { HomeBridge.shared.moreHome(token: token, callback: $0) }
    }

    func explore() async throws -> FeedResult {
        try await fetch { HomeBridge.shared.explore(callback: $0) }
    }

    func moreExplore(token: String) async throws -> FeedResult {
        try await fetch { HomeBridge.shared.moreExplore(token: token, callback: $0) }
    }

    func history() async throws -> [YouTubeSong] {
        try await withCheckedThrowingContinuation { continuation in
            HomeBridge.shared.history(callback: FeedCallbackAdapter { json, message in
                if let json {
                    do {
                        let songs = try JSONDecoder().decode([YouTubeSong].self, from: Data(json.utf8))
                        continuation.resume(returning: songs)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: FeedError(message: message ?? "history failed"))
                }
            })
        }
    }

    func library() async throws -> [FeedShelf] {
        try await withCheckedThrowingContinuation { continuation in
            LibraryBridge.shared.library(callback: LibraryFeedAdapter { json, message in
                if let json {
                    do {
                        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
                        continuation.resume(returning: page.shelves)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: FeedError(message: message ?? "library failed"))
                }
            })
        }
    }

    private func fetch(_ call: @escaping (HomeBridgeFeedCallback) -> Void) async throws -> FeedResult {
        try await withCheckedThrowingContinuation { continuation in
            call(FeedCallbackAdapter { json, message in
                if let json {
                    do {
                        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
                        continuation.resume(returning: FeedResult(
                            shelves: page.shelves,
                            continuation: page.continuation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: FeedError(message: message ?? "feed failed"))
                }
            })
        }
    }

    struct FeedError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

private final class FeedCallbackAdapter: HomeBridgeFeedCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

private final class LibraryFeedAdapter: LibraryBridgeFeedCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

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

/// A grid of mood/genre buttons, as YouTube Music groups them. Decoded from the
/// shared module's serialized `MoodGenreSection` list, same JSON contract as
/// every other bridge here.
struct MoodGenreSection: Decodable, Identifiable {
    let title: String
    /// Not a `let`, for the same reason [MoodGenre.thumbnailUrl] is not: the
    /// grid is published again as each section's covers arrive.
    var items: [MoodGenre]
    var id: String { title }
}

/// A category button. [params] travels with the id rather than being folded into
/// it — YouTube's `browseEndpoint` takes the two separately, and a mood category
/// without its own params answers with a different, generic page rather than an
/// error, so a lost `params` looks like a working feature returning the wrong
/// thing.
struct MoodGenre: Decodable, Identifiable, Hashable {
    let title: String
    let browseId: String
    let params: String?
    /// Not a `let`: the category grid paints first and the artwork is filled in
    /// afterwards, one section at a time, so the first covers to arrive are on
    /// screen while the rest are still being asked for.
    var thumbnailUrl: String?
    var id: String { "\(browseId)?\(params ?? "")" }
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

    /// The mood and genre categories behind Explore.
    func moodAndGenres() async throws -> [MoodGenreSection] {
        try await withCheckedThrowingContinuation { continuation in
            HomeBridge.shared.moodAndGenres(callback: MoodCallbackAdapter { json, message in
                guard let json else {
                    continuation.resume(throwing: InnertubeFeed.FeedError(
                        message: message ?? "no mood or genre categories"
                    ))
                    return
                }
                do {
                    continuation.resume(returning: try JSONDecoder().decode(
                        [MoodGenreSection].self, from: Data(json.utf8)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            })
        }
    }

    /// One category's playlist shelves.
    func moodGenreShelves(browseId: String, params: String?) async throws -> [FeedShelf] {
        try await fetch {
            HomeBridge.shared.moodGenreShelves(browseId: browseId, params: params, callback: $0)
        }.shelves
    }

    /// A category's tile artwork — the first real cover from the playlists it
    /// opens, fetched after the grid has painted.
    func moodGenreArtwork(browseId: String, params: String?) async -> String? {
        await withCheckedContinuation { continuation in
            HomeBridge.shared.moodGenreArtwork(
                browseId: browseId, params: params,
                callback: ArtworkCallbackAdapter { url, _ in
                    continuation.resume(returning: url)
                }
            )
        }
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

private final class MoodCallbackAdapter: HomeBridgeMoodCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

private final class ArtworkCallbackAdapter: HomeBridgeArtworkCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(url: String?, message: String?) { onResult(url, message) }
}

private final class LibraryFeedAdapter: LibraryBridgeFeedCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

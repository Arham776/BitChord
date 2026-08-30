import Foundation
import BitChordShared

struct DetailPageModel: Decodable {
    let browseId: String
    let title: String
    let subtitle: String
    let thumbnailUrl: String?
    let songs: [SongPayload]
    let sections: [FeedShelf]
    let description: String?
    let subscriberCountText: String?
    let monthlyListenerCount: String?
    let continuation: String?
    // Kotlin's DetailPage adds `type` (BrowseType) which we ignore in Swift – keep decoder tolerant.
    let type: String?

    enum CodingKeys: String, CodingKey {
        case browseId, title, subtitle, thumbnailUrl, songs, sections, description, subscriberCountText, monthlyListenerCount, continuation, type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browseId = try c.decodeIfPresent(String.self, forKey: .browseId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        songs = try c.decodeIfPresent([SongPayload].self, forKey: .songs) ?? []
        sections = try c.decodeIfPresent([FeedShelf].self, forKey: .sections) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description)
        subscriberCountText = try c.decodeIfPresent(String.self, forKey: .subscriberCountText)
        monthlyListenerCount = try c.decodeIfPresent(String.self, forKey: .monthlyListenerCount)
        continuation = try c.decodeIfPresent(String.self, forKey: .continuation)
        type = try c.decodeIfPresent(String.self, forKey: .type)
    }

    struct SongPayload: Decodable {
        let videoId: String
        let title: String
        let artist: String
        let thumbnailUrl: String?
        let durationText: String?
        let albumName: String?
        let isVideo: Bool
        let artistId: String?
        let albumId: String?

        enum CodingKeys: String, CodingKey {
            case videoId, title, artist, thumbnailUrl, durationText, albumName, isVideo, artistId, albumId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            videoId = try c.decode(String.self, forKey: .videoId)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown artist"
            thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
            durationText = try c.decodeIfPresent(String.self, forKey: .durationText)
            albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
            isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
            artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
            albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        }
    }
}

final class InnertubeDetail: Sendable {
    static let shared = InnertubeDetail()

    func browse(browseId: String) async throws -> DetailPageModel {
        try await withCheckedThrowingContinuation { cont in
            DetailBridge.shared.browse(browseId: browseId, callback: DetailCallback { json, msg in
                if let json {
                    do {
                        // Log JSON for diagnostics then decode leniently
                        // print("[Detail] json \(json.prefix(500))")
                        let page = try JSONDecoder().decode(DetailPageModel.self, from: Data(json.utf8))
                        cont.resume(returning: page)
                    } catch {
                        print("[Detail] decode failed: \(error) json: \(json.prefix(1000))")
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(throwing: DetailError(msg ?? "browse failed"))
                }
            })
        }
    }

    func browseArtist(browseId: String) async throws -> DetailPageModel {
        try await withCheckedThrowingContinuation { cont in
            DetailBridge.shared.browseArtist(browseId: browseId, callback: DetailCallback { json, msg in
                if let json {
                    do {
                        let page = try JSONDecoder().decode(DetailPageModel.self, from: Data(json.utf8))
                        cont.resume(returning: page)
                    } catch {
                        print("[Detail] decode artist failed: \(error)")
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(throwing: DetailError(msg ?? "browse failed"))
                }
            })
        }
    }

    struct DetailError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

private final class DetailCallback: DetailBridgeDetailCallback {
    let onResult: (String?, String?) -> Void
    init(_ cb: @escaping (String?, String?) -> Void) { onResult = cb }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

import Foundation
import BitChordShared

/// Swift wrappers over `LibraryActionsBridge` (likes, playlists, library save).
@MainActor
enum LibraryActions {
    static func rate(videoId: String, status: String) async -> String? {
        LikeStore.shared.set(videoId, status)
        return await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.rate(videoId: videoId, status: status, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    /// Toggle the heart on `videoId` — write the rating to the screen first and
    /// roll it back if YouTube refuses. Upstream `MainViewModel.setLike`.
    ///
    /// A rating is a one-tap, low-stakes action taken while a song is playing;
    /// waiting on a round trip before the heart fills reads as the tap not
    /// having registered, and people tap again. The rollback is the other half
    /// of that bargain, and the port was missing it: every call site wrote the
    /// result of `rate` to `_`, so a rating YouTube refused left the heart
    /// showing a status the account did not have and said nothing about it.
    ///
    /// - Returns: the failure message, or `nil` on success.
    static func toggleLike(videoId: String) async -> String? {
        let generation = PageSession.generation()
        let previous = cachedLike(videoId)
        let next = previous == "LIKE" ? "INDIFFERENT" : "LIKE"
        let failure = await rate(videoId: videoId, status: next)
        if failure != nil, generation == PageSession.generation() {
            // `rate` already wrote `next` optimistically; put it back.
            LikeStore.shared.set(videoId, previous)
        }
        return failure
    }

    static func ratePlaylist(playlistId: String, saved: Bool) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.ratePlaylist(playlistId: playlistId, saved: saved, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func setSubscribed(channelId: String, subscribed: Bool) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.setSubscribed(
                channelId: channelId,
                subscribed: subscribed,
                callback: DoneCB { ok, msg in cont.resume(returning: ok ? nil : msg) }
            )
        }
    }

    static func createPlaylist(title: String, privacy: String, videoId: String?) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.createPlaylist(title: title, privacy: privacy, videoId: videoId, callback: JsonCB(invalidateOnSuccess: true) { json, _ in
                cont.resume(returning: json)
            })
        }
    }

    static func deletePlaylist(playlistId: String) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.deletePlaylist(playlistId: playlistId, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func addToPlaylist(playlistId: String, videoId: String) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.addToPlaylist(playlistId: playlistId, videoId: videoId, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func removeFromPlaylist(playlistId: String, setVideoId: String, videoId: String) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.removeFromPlaylist(playlistId: playlistId, setVideoId: setVideoId, videoId: videoId, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func renamePlaylist(playlistId: String, title: String) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.renamePlaylist(playlistId: playlistId, title: title, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func setPlaylistPrivacy(playlistId: String, privacy: String) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.setPlaylistPrivacy(playlistId: playlistId, privacy: privacy, callback: DoneCB { ok, msg in
                cont.resume(returning: ok ? nil : msg)
            })
        }
    }

    static func movePlaylistItem(playlistId: String, setVideoId: String, successorSetVideoId: String?) async -> String? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.movePlaylistItem(
                playlistId: playlistId,
                setVideoId: setVideoId,
                successorSetVideoId: successorSetVideoId,
                callback: DoneCB { ok, msg in
                    cont.resume(returning: ok ? nil : msg)
                }
            )
        }
    }

    /// Drops later copies of the same video, keeping the first occurrence.
    static func removeDuplicates(
        playlistId: String,
        songs: [(setVideoId: String, videoId: String)]
    ) async -> String? {
        let generation = PageSession.generation()
        var seen = Set<String>()
        var extras: [(String, String)] = []
        for song in songs {
            if seen.contains(song.videoId) {
                extras.append((song.setVideoId, song.videoId))
            } else {
                seen.insert(song.videoId)
            }
        }
        for extra in extras {
            guard generation == PageSession.generation() else { return "Account changed; reload before trying again" }
            if let err = await removeFromPlaylist(playlistId: playlistId, setVideoId: extra.0, videoId: extra.1) {
                return err
            }
        }
        guard generation == PageSession.generation() else { return "Account changed; reload before trying again" }
        return extras.isEmpty ? "No duplicates" : nil
    }

    static func userPlaylists() async -> [UserPlaylistDTO] {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.userPlaylists(callback: JsonCB { json, _ in
                guard let json, let data = json.data(using: .utf8),
                      let list = try? JSONDecoder().decode([UserPlaylistDTO].self, from: data) else {
                    cont.resume(returning: [])
                    return
                }
                cont.resume(returning: list)
            })
        }
    }

    static func songMenu(videoId: String) async -> SongMenuDTO? {
        await withCheckedContinuation { cont in
            LibraryActionsBridge.shared.songMenu(videoId: videoId, callback: JsonCB { json, _ in
                guard let json, let data = json.data(using: .utf8) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: try? JSONDecoder().decode(SongMenuDTO.self, from: data))
            })
        }
    }

    static func cachedLike(_ videoId: String) -> String {
        LikeStore.shared.status(videoId)
    }
}

/// Optimistic ratings so hearts update immediately — same role as upstream `LikeState`.
@MainActor
@Observable
final class LikeStore {
    static let shared = LikeStore()
    private var map: [String: String] = [:]
    private(set) var epoch = 0

    func status(_ videoId: String) -> String {
        map[videoId] ?? LibraryActionsBridge.shared.likeStatus(videoId: videoId)
    }

    func clear() { map.removeAll(); epoch += 1 }

    func set(_ videoId: String, _ status: String) {
        map[videoId] = status
        epoch += 1
    }
}

struct UserPlaylistDTO: Codable, Identifiable, Hashable {
    let playlistId: String
    let title: String
    let subtitle: String
    let thumbnailUrl: String?
    var id: String { playlistId }
    var browseId: String { playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)" }
}

struct SongMenuDTO: Codable {
    let likeStatus: String?
    let inLibrary: Bool?
    let addToLibraryToken: String?
    let removeFromLibraryToken: String?
}

private final class DoneCB: LibraryActionsBridgeDoneCallback {
    let handler: (Bool, String?) -> Void
    let context: PageContext
    @MainActor init(_ handler: @escaping (Bool, String?) -> Void) {
        self.handler = handler; context = PageSession.capture()
    }
    func onResult(ok: Bool, message: String?) {
        Task { @MainActor in
            guard context.generation == PageSession.generation() else {
                handler(false, "Account changed; reload before trying again"); return
            }
            if ok {
                await PageRequestCoordinator.shared.invalidate(partition: context.partition)
            }
            guard context.generation == PageSession.generation() else {
                handler(false, "Account changed; reload before trying again"); return
            }
            handler(ok, message)
        }
    }
}

private final class JsonCB: LibraryActionsBridgeJsonCallback {
    let handler: (String?, String?) -> Void
    let context: PageContext
    let invalidateOnSuccess: Bool
    @MainActor init(invalidateOnSuccess: Bool = false, _ handler: @escaping (String?, String?) -> Void) {
        self.handler = handler; self.invalidateOnSuccess = invalidateOnSuccess
        context = PageSession.capture()
    }
    func onResult(json: String?, message: String?) {
        Task { @MainActor in
            guard context.generation == PageSession.generation() else {
                handler(nil, "Account changed; reload before trying again"); return
            }
            if invalidateOnSuccess, json != nil {
                await PageRequestCoordinator.shared.invalidate(partition: context.partition)
            }
            guard context.generation == PageSession.generation() else {
                handler(nil, "Account changed; reload before trying again"); return
            }
            handler(json, message)
        }
    }
}

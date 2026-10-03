import Foundation

/// Queue snapshot so a cold start opens on the track that was current —
/// upstream `LastPlayed`. Restored idle: no stream resolve until Play.
enum LastPlayed {
    struct Snapshot {
        var tracks: [QueueEntry]
        var index: Int
        var position: Double
        var repeatMode: PlaybackController.RepeatMode
        var shuffleEnabled: Bool
        var volume: Double
        var contextID: String?
        var contextTitle: String?
    }

    private static let key = "bitchord_last_played"
    private static let keepBehind = 10
    private static let maxTracks = 60

    static func save(
        tracks: [QueueEntry],
        index: Int,
        position: Double,
        repeatMode: PlaybackController.RepeatMode,
        shuffleEnabled: Bool,
        volume: Double,
        contextID: String? = nil,
        contextTitle: String? = nil
    ) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        let start = max(0, min(index - keepBehind, max(0, tracks.count - maxTracks)))
        let end = min(tracks.count, start + maxTracks)
        let window = Array(tracks[start..<end])
        let stored = Stored(
            tracks: window.map(StoredTrack.init),
            index: (index - start).clamped(to: 0...max(0, window.count - 1)),
            positionMs: Int64(max(0, position) * 1000),
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            volume: volume,
            contextID: contextID,
            contextTitle: contextTitle
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.tracks.isEmpty else { return nil }
        let tracks = stored.tracks.map(\.entry)
        return Snapshot(
            tracks: tracks,
            index: stored.index.clamped(to: 0...max(0, tracks.count - 1)),
            position: Double(max(0, stored.positionMs)) / 1000,
            repeatMode: PlaybackController.RepeatMode(rawValue: stored.repeatMode) ?? .off,
            shuffleEnabled: stored.shuffle,
            volume: stored.volume > 0 ? min(stored.volume, 1) : 0.9,
            contextID: stored.contextID,
            contextTitle: stored.contextTitle
        )
    }

    private struct Stored: Codable {
        var tracks: [StoredTrack]
        var index: Int
        var positionMs: Int64
        var repeatMode: Int
        var shuffle: Bool
        var volume: Double
        var contextID: String?
        var contextTitle: String?
    }

    private struct StoredTrack: Codable {
        var id: String
        var title: String
        var artist: String
        var source: String
        var thumbnailUrl: String?
        var durationText: String?
        var albumName: String?
        var isLocal: Bool
        var fromAutoplay: Bool
        var artistId: String?
        var albumId: String?
        var setVideoId: String?
        var contextOrder: Int?

        init(_ entry: QueueEntry) {
            id = entry.id
            title = entry.title
            artist = entry.artist
            source = entry.source
            thumbnailUrl = entry.thumbnailUrl
            durationText = entry.durationText
            albumName = entry.albumName
            isLocal = entry.isLocal
            fromAutoplay = entry.fromAutoplay
            artistId = entry.artistId
            albumId = entry.albumId
            setVideoId = entry.setVideoId
            contextOrder = entry.contextOrder
        }

        var entry: QueueEntry {
            QueueEntry(
                id: id, title: title, artist: artist, source: source,
                thumbnailUrl: thumbnailUrl, durationText: durationText,
                albumName: albumName, artworkData: nil, isLocal: isLocal,
                fromAutoplay: fromAutoplay, artistId: artistId, albumId: albumId,
                setVideoId: setVideoId, contextOrder: contextOrder
            )
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

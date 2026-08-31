import Foundation
import BitChordShared

/// Local listening aggregates for Replay — same sampling idea as upstream
/// `ListeningRecorder` / `ListeningStats`, stored in UserDefaults.
@MainActor
final class ListeningStore {
    static let shared = ListeningStore()

    private let key = "listening_stats_v1"
    private var currentId: String?
    private var lastSampleAt: Date?
    private var playedThisTrack: TimeInterval = 0
    private var playCounted = false
    /// Filled by Replay after `ArtistFacts.warmup` so genre ranking is MainActor-cheap.
    var knownGenres: [String: [String]] = [:]

    struct Bucket: Codable {
        var tracks: [String: Track] = [:]
        var days: [String: Double] = [:]
    }

    struct Track: Codable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var albumId: String?
        var artistId: String?
        var art: String?
        var ms: Double
        var plays: Int
    }

    private var bucket: Bucket

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Bucket.self, from: data) {
            bucket = decoded
        } else {
            bucket = Bucket()
        }
    }

    func onSample(id: String, title: String, artist: String, album: String?, albumId: String?, artistId: String?, art: String?, duration: Double) {
        let now = Date()
        if id != currentId {
            currentId = id
            lastSampleAt = now
            playedThisTrack = 0
            playCounted = false
            return
        }
        guard let last = lastSampleAt else { lastSampleAt = now; return }
        let step = min(now.timeIntervalSince(last), 4)
        lastSampleAt = now
        guard step > 0 else { return }
        playedThisTrack += step
        let length = duration > 0 ? duration : 0
        let threshold = length > 0 ? min(max(length / 2, 30), 240) : 30
        let counts = !playCounted && playedThisTrack >= threshold
        if counts { playCounted = true }
        var track = bucket.tracks[id] ?? Track(
            id: id, title: title, artist: artist, album: album,
            albumId: albumId, artistId: artistId, art: art, ms: 0, plays: 0
        )
        track.title = title
        track.artist = artist
        if let album { track.album = album }
        track.ms += step * 1000
        if counts { track.plays += 1 }
        bucket.tracks[id] = track
        let day = ISO8601DateFormatter().string(from: now).prefix(10)
        bucket.days[String(day), default: 0] += step * 1000
        persist()
    }

    func onStopped() {
        currentId = nil
        lastSampleAt = nil
        persist()
    }

    func persist() {
        if let data = try? JSONEncoder().encode(bucket) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func summary(includeGenres: Bool = true) -> ReplaySummary {
        let withGenres = includeGenres && ArtistFacts.genresEnabled
        let songs = bucket.tracks.values.sorted { $0.ms > $1.ms }
        var artistMs: [String: (ms: Double, plays: Int, id: String?)] = [:]
        var albumMs: [String: (ms: Double, id: String?)] = [:]
        for t in bucket.tracks.values {
            var a = artistMs[t.artist] ?? (0, 0, t.artistId)
            a.ms += t.ms
            a.plays += t.plays
            artistMs[t.artist] = a
            if let album = t.album, !album.isEmpty {
                var al = albumMs[album] ?? (0, t.albumId)
                al.ms += t.ms
                albumMs[album] = al
            }
        }
        var genres: [Ranked] = []
        if withGenres {
            // Snapshot of the Last.fm cache — warmup fills it asynchronously.
            var genreMs: [String: Double] = [:]
            for t in bucket.tracks.values {
                for genre in (knownGenres[t.artist] ?? []) {
                    genreMs[genre, default: 0] += t.ms
                }
            }
            genres = genreMs.map { Ranked(name: $0.key, ms: $0.value, browseId: nil) }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 }
        }
        let busiest = bucket.days.max { $0.value < $1.value }
        return ReplaySummary(
            totalMs: bucket.tracks.values.reduce(0) { $0 + $1.ms },
            totalPlays: bucket.tracks.values.reduce(0) { $0 + $1.plays },
            songs: Array(songs.prefix(10)),
            artists: artistMs.map { Ranked(name: $0.key, ms: $0.value.ms, browseId: $0.value.id) }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 },
            albums: albumMs.map { Ranked(name: $0.key, ms: $0.value.ms, browseId: $0.value.id) }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 },
            genres: genres,
            busiestDay: busiest.map { String($0.key) },
            busiestDayMs: busiest?.value ?? 0
        )
    }

    func exportJSON() -> Data? { try? JSONEncoder().encode(bucket) }

    func importJSON(_ data: Data) {
        if let decoded = try? JSONDecoder().decode(Bucket.self, from: data) {
            bucket = decoded
            persist()
        }
    }
}

struct Ranked: Identifiable {
    var name: String
    var ms: Double
    var browseId: String?
    var id: String { name }
}

struct ReplaySummary {
    var totalMs: Double
    var totalPlays: Int
    var songs: [ListeningStore.Track]
    var artists: [Ranked]
    var albums: [Ranked]
    var genres: [Ranked] = []
    var busiestDay: String?
    var busiestDayMs: Double
    var minutes: Int { Int(totalMs / 60_000) }
    var isEmpty: Bool { songs.isEmpty }
}

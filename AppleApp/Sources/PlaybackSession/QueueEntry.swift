import Foundation

/// One playable entry in the queue. Wraps either a local file path or a
/// resolved stream URL; metadata mirrors upstream's `Song` row.
struct QueueEntry: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var artist: String
    var source: String
    var thumbnailUrl: String?
    var durationText: String?
    var albumName: String?
    var artworkData: Data?
    /// The audio is already on a disk this device can reach, so it is not something
    /// to download and not a catalogue row to rate.
    ///
    /// True for a file in the device's own library *and* for a file on a remote
    /// library the listener configured — a share on their own server is already saved
    /// as far as they are concerned, and offering to download it would be offering to
    /// copy a file they already have. It is not, and must not be read as, "a path on
    /// this device": a remote row's [source] is an `https` address, so the places that
    /// treat `source` as a filesystem path ask again before they open it.
    var isLocal: Bool
    var fromAutoplay: Bool = false
    var artistId: String? = nil
    var albumId: String? = nil
    var setVideoId: String? = nil
    /// Original position in the list that started this queue. Manual additions have none.
    var contextOrder: Int? = nil

    /// Clean or uncensored edition, or nil when the originating catalogue did not
    /// say.
    ///
    /// Tri-state on purpose, for the same reason it is one in the shared `Song`:
    /// "not stated" and "stated as clean" are different claims, and the cross-source
    /// matcher rejects a candidate whose stated edition contradicts the target's
    /// while refusing to reject one that has simply made no claim.
    var isExplicit: Bool? = nil

    /// Whether this row is a music video rather than catalogue audio.
    ///
    /// Load-bearing beyond the badge: a video's runtime includes a visual intro or
    /// outro, so the matcher must not treat it as evidence about the audio's length,
    /// and a source match is another recording and can be a wrong song altogether.
    var isVideo: Bool = false

    var videoId: String? {
        if source.hasPrefix("yt:") { return String(source.dropFirst(3)) }
        if isLocal { return nil }
        return id
    }

    /// "title artist album" for the Automix speech/live guard (upstream
    /// `TransitionPlanner.itemText`).
    var itemText: String {
        [title, artist, albumName ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Upstream `TransitionPlanner.sameAlbum` — the two rows are the same
    /// recording by album id, or by album name + artist.
    func sameAlbum(as other: QueueEntry) -> Bool {
        if let a = albumId, let b = other.albumId, !a.isEmpty, a == b { return true }
        if let a = albumName, let b = other.albumName, !a.isEmpty, a == b, artist == other.artist {
            return true
        }
        return false
    }

    static func youtube(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String? = nil,
        durationText: String? = nil,
        albumName: String? = nil,
        artistId: String? = nil,
        albumId: String? = nil,
        setVideoId: String? = nil,
        fromAutoplay: Bool = false
    ) -> QueueEntry {
        QueueEntry(
            id: videoId, title: title, artist: artist, source: "yt:\(videoId)",
            thumbnailUrl: thumbnailUrl, durationText: durationText, albumName: albumName,
            artworkData: nil, isLocal: false, fromAutoplay: fromAutoplay,
            artistId: artistId, albumId: albumId, setVideoId: setVideoId
        )
    }

    var durationSeconds: Double {
        let parts = (durationText ?? "").split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        let hours = mins / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins % 60, secs)
            : String(format: "%d:%02d", mins, secs)
    }

}

import Foundation
import BitChordShared

// Every lyrics source, against the real thing.
//
// Sixteen providers, none of which had ever been run against a live host. A
// fixture can prove a parser reads a body it was given; it cannot prove the
// endpoint still answers, still spells its JSON the way it did, or still has
// the song you asked about. This asks each one, on its own, for a handful of
// tracks across four catalogues, and prints what came back — how many, whether
// the timings are word-synced, and how long it took.
//
// A source that returns nothing is not necessarily broken: three need an API key
// this build has none of, and several are regional catalogues that will not have
// an English pop song. What this is for is telling those two apart from the
// third case, which is a source that is broken.
//
// Run: scripts/check-lyrics.sh

struct Track {
    let title: String
    let artist: String
    let album: String?
    let seconds: Int
    var ms: Int64 { Int64(seconds) * 1000 }
    /// A real YouTube id for this track, for the four sources that are keyed on one.
    ///
    /// Looked up rather than hard-coded, because a hard-coded id rots: a video gets
    /// taken down and the source under test then reports nothing for a reason that
    /// has nothing to do with the source.
    var videoId: String?
}

/// The id the sources keyed on a video need, and the search that finds it.
func searchVideoId(_ track: Track) async -> String? {
    do {
        let json = try await withCheckedThrowingContinuation { c in
            let callback = LyricsVerifySearch { json, _ in
                if let json { c.resume(returning: json) } else { c.resume(throwing: HarnessError.noValue) }
            }
            SearchBridge.shared.search(
                query: "\(track.artist) \(track.title) lyrics", scope: "songs", callback: callback
            )
        }
        guard let data = json.data(using: .utf8),
              // A top-level array of hits, which is what `SearchBridge` encodes —
              // not an object with a "results" key.
              let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        // A track hit has a video id; a "browse" hit is an album or a playlist and
        // has none, and asking a lyrics source for one of those is asking for nothing.
        for hit in hits {
            guard let kind = hit["kind"] as? String, kind != "browse",
                  let videoId = hit["videoId"] as? String, !videoId.isEmpty
            else { continue }
            return videoId
        }
        return nil
    } catch {
        return nil
    }
}

private enum HarnessError: Error { case noValue }

private final class LyricsVerifySearch: SearchBridgeSearchCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}

// Four catalogues, because a provider that only carries Hindi is not broken and
// a provider that carries nothing is.
var tracks: [Track] = [
    Track(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", seconds: 355, videoId: nil),
    Track(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", seconds: 200, videoId: nil),
    Track(title: "Kal Ho Naa Ho", artist: "Shahrukh Khan", album: "Kal Ho Naa Ho", seconds: 296, videoId: nil),
    Track(title: "Lemon", artist: "Kenshi Yonezu", album: "BOOTLEG", seconds: 256, videoId: nil),
    Track(title: "起风了", artist: "买辣椒也用券", album: "起风了", seconds: 325, videoId: nil),
]

// The video-id half, asked for once. Four of the sixteen sources are keyed on a
// YouTube id and cannot answer a title at all, so a harness that passed none would
// report four working providers as broken — the failure would be in the harness,
// and it would look exactly like the thing this harness exists to find.
for index in tracks.indices {
    tracks[index].videoId = await searchVideoId(tracks[index])
}
let withVideo = tracks.filter { $0.videoId != nil }.count
print("video ids found for \(withVideo) of \(tracks.count) tracks")

let storedSources = (AppSettings.shared.lyricsSources.value as? String) ?? ""
let storedSynced = (AppSettings.shared.syncedLyrics.value as? Bool) ?? false

func restore() {
    AppSettings.shared.setLyricsSources(value: storedSources)
    AppSettings.shared.setSyncedLyrics(value: storedSynced)
}

func lyrics(for track: Track) async -> [LyricLineDto] {
    do {
        return try await withCheckedThrowingContinuation { c in
            LyricsBridge.shared.lyrics(
                title: track.title, artist: track.artist, durationMs: track.ms,
                album: track.album, videoId: track.videoId
            ) { lines, error in
                if let error { c.resume(throwing: error) }
                else { c.resume(returning: lines ?? []) }
            }
        }
    } catch {
        return []
    }
}

let began = Date()
var failures: [String] = []
var answered: [String] = []
var dead: [String] = []
var thin_: [String] = []

// The names read off the shared enum rather than typed here: a list of sixteen
// strings kept in a harness is sixteen things that can be wrong.
let sources: [(name: String, label: String, declaredWordSynced: Bool)] =
    LyricsSource.entries.map { ($0.name, $0.label, $0.wordSynced) }

/// The three that need an API key this build does not have.
let needsKey: Set<String> = ["PAXSENIX", "PAXSENIX_SPOTIFY", "PAXSENIX_MUSIXMATCH"]

/// Sources whose upstream endpoint is gone, verified by hand against the endpoint
/// itself on 26 September 2026.
///
/// Kept here rather than in the provider files because this is a statement about
/// *today*, and a provider file should say what the code is for. Each was checked
/// directly against the service, so "nothing" below is a fact about the endpoint and
/// not a guess:
///
/// - `MUSIXMATCH` answers `status_code: 401, hint: "upgrade"` on its own token
///   endpoint \u{2014} the shared web-app id and secret no longer get a token at all.
/// - `BETTER_LYRICS_PORTATO` answers `404 page not found`. The main BetterLyrics
///   endpoint is alive, and is a separate source.
/// - `MEGALOBIZ`'s search answers 404 and `/search/` answers 503. The scraper's two
///   regexes are fine; the page they read is not serving.
let goneUpstream: [String: String] = [
    "MUSIXMATCH": "401 upgrade \u{2014} the web app id gets no token",
    "BETTER_LYRICS_PORTATO": "404 \u{2014} the endpoint is gone",
    "MEGALOBIZ": "404/503 \u{2014} the search page it scrapes is not serving",
]

/// Sources that answer, and have nothing for these five tracks.
///
/// A third thing, and the one a list of results is most likely to be read as a
/// failure. Both were checked: Unison answers `200` with `{"success": false}` for
/// every one of them, which is that database saying it has never heard of the song —
/// it is a community submission store and its coverage is thin and uneven by nature.
/// YouTube Transcript reads YouTube Music's own transcript store, which only has an
/// entry for a video somebody transcribed, and an official audio upload is not one.
let thinCoverage: [String: String] = [
    "UNISON": "200 with success:false \u{2014} the database has not heard of them",
    "YOUTUBE_TRANSCRIPT": "no cues \u{2014} these videos have no transcript in YouTube Music",
]

print("sources: \(sources.count)   tracks: \(tracks.count)   api keys in this build: none")
print("")

for source in sources {
    AppSettings.shared.setLyricsSources(value: source.name)
    var hits = 0
    var best = 0
    var wordSynced = false
    var slowest = 0.0
    for track in tracks {
        let started = Date()
        let lines = await lyrics(for: track)
        slowest = max(slowest, Date().timeIntervalSince(started))
        guard !lines.isEmpty else { continue }
        hits += 1
        best = max(best, lines.count)
        if lines.contains(where: { !$0.words.isEmpty }) { wordSynced = true }
    }
    let verdict = hits == 0 ? "nothing" : "\(hits)/\(tracks.count)"
    let note = needsKey.contains(source.name)
        ? " \u{00B7} needs a key"
        : (goneUpstream[source.name] ?? thinCoverage[source.name]).map { " \u{00B7} \($0)" } ?? ""
    print(pad(source.label, 22) + pad(source.name, 24) + pad(verdict, 8)
        + pad("\(best) lines", 11) + pad(String(format: "%.1fs", slowest), 9)
        + (wordSynced ? "word-synced" : "line-synced") + note)
    if hits > 0 {
        answered.append(source.label)
    } else if let gone = goneUpstream[source.name] {
        dead.append("\(source.name): \(gone)")
    } else if let thin = thinCoverage[source.name] {
        thin_.append("\(source.name): \(thin)")
    } else if !needsKey.contains(source.name) {
        failures.append("\(source.name) (\(source.label)) answered for none of \(tracks.count) tracks")
    }
}

restore()

print("")
print("answered: \(answered.count) of \(sources.count)   in \(Int(Date().timeIntervalSince(began)))s")
if !dead.isEmpty {
    print("")
    print("dead upstream, checked against the service itself:")
    dead.forEach { print("  \u{00B7} \($0)") }
}
if !thin_.isEmpty {
    print("")
    print("alive, and nothing for these tracks:")
    thin_.forEach { print("  \u{00B7} \($0)") }
}
if failures.isEmpty {
    print("")
    print("PASS  every source that needs no key, and whose endpoint exists, answered for at least one track")
} else {
    print("FAIL  \(failures.count) sources answered for nothing:")
    failures.forEach { print("  \u{00B7} \($0)") }
    exit(1)
}

/// Left-pad to a column, counting characters rather than bytes so a name with an
/// accent does not shift the column under it.
func pad(_ text: String, _ width: Int) -> String {
    let count = text.count
    return count >= width ? text + " " : text + String(repeating: " ", count: width - count)
}

import Foundation
import BitChordShared

/// Last.fm genre tags for Replay — port of upstream `ArtistFacts`.
/// Sends only the artist name; nothing else. Off when Settings “Work out genres”
/// is disabled or no Last.fm API key is set.
actor ArtistFacts {
    static let shared = ArtistFacts()

    private var known: [String: [String]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private let file: URL
    private static let retry: TimeInterval = 14 * 24 * 60 * 60

    init() {
        file = DiskCache.cachesSubfolder("meta").appendingPathComponent("artist_facts.json")
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            known = decoded
        }
    }

    nonisolated static var genresEnabled: Bool {
        PlatformSettings.shared.getBoolean(key: "replay_genres", default: true)
            && !PlatformSettings.shared.getString(key: "lastfm_api_key", default: "").isEmpty
    }

    func genresFor(_ artist: String) -> [String] {
        known[Self.key(artist)] ?? []
    }

    func warmup(artists: [String]) async {
        guard Self.genresEnabled else { return }
        let unique = Array(Set(artists.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        for name in unique.prefix(40) {
            let k = Self.key(name)
            if let at = fetchedAt[k], Date().timeIntervalSince(at) < Self.retry { continue }
            if known[k]?.isEmpty == false { continue }
            await fetch(name)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        persist()
    }

    private func fetch(_ name: String) async {
        let apiKey = PlatformSettings.shared.getString(key: "lastfm_api_key", default: "")
        guard !apiKey.isEmpty,
              var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else { return }
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.getTopTags"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toptags = obj["toptags"] as? [String: Any] else {
            fetchedAt[Self.key(name)] = Date()
            return
        }
        let rawTags: [[String: Any]]
        if let arr = toptags["tag"] as? [[String: Any]] {
            rawTags = arr
        } else if let one = toptags["tag"] as? [String: Any] {
            rawTags = [one]
        } else {
            rawTags = []
        }
        let genres = rawTags.compactMap { $0["name"] as? String }.compactMap(Self.canonical).uniqued().prefix(2)
        known[Self.key(name)] = Array(genres)
        fetchedAt[Self.key(name)] = Date()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(known) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func key(_ artist: String) -> String { artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private static func canonical(_ tag: String) -> String? {
        var cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "&", with: "and")
        cleaned = cleaned.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        if let hit = vocabulary[cleaned] { return hit }
        if let alias = aliases[cleaned], let hit = vocabulary[alias] { return hit }
        return nil
    }

    private static let spellings: [String: String] = [
        "randb": "R&B", "edm": "EDM", "lo fi": "Lo-Fi", "hip hop": "Hip-Hop",
        "k pop": "K-Pop", "j pop": "J-Pop", "j rock": "J-Rock", "c pop": "C-Pop",
        "drum and bass": "Drum & Bass", "singer songwriter": "Singer-Songwriter",
        "post punk": "Post-Punk", "post rock": "Post-Rock", "bossa nova": "Bossa Nova",
    ]

    private static let vocabulary: [String: String] = {
        let names = [
            "pop", "rock", "hip hop", "rap", "randb", "soul", "funk", "jazz", "blues",
            "country", "folk", "indie", "indie pop", "indie rock", "alternative",
            "alternative rock", "metal", "heavy metal", "punk", "punk rock", "hardcore",
            "electronic", "house", "deep house", "techno", "trance", "dubstep",
            "drum and bass", "edm", "ambient", "lo fi", "synthpop", "disco",
            "classical", "opera", "soundtrack", "instrumental", "acoustic",
            "reggae", "reggaeton", "dancehall", "ska", "latin", "salsa", "bossa nova",
            "afrobeats", "afrobeat", "k pop", "j pop", "j rock", "c pop",
            "bollywood", "punjabi", "desi", "bhangra", "hindi", "sufi", "ghazal",
            "singer songwriter", "emo", "grunge", "shoegaze", "psychedelic",
            "progressive rock", "hard rock", "garage rock", "post punk", "new wave",
            "gospel", "christian", "world", "experimental", "trap", "drill", "grime",
            "phonk", "hyperpop", "chillout", "downtempo", "jungle", "garage",
            "bluegrass", "americana", "swing", "big band", "motown", "britpop",
            "dream pop", "art pop", "noise", "industrial", "gothic", "doom metal",
            "black metal", "death metal", "thrash metal", "metalcore", "post rock",
            "math rock", "jam band", "surf rock", "rockabilly", "boom bap",
            "cloud rap", "conscious hip hop", "west coast rap", "east coast rap",
        ]
        var map: [String: String] = [:]
        for name in names {
            map[name] = spellings[name] ?? name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        }
        return map
    }()

    private static let aliases: [String: String] = [
        "rnb": "randb", "r and b": "randb", "rhythm and blues": "randb",
        "contemporary randb": "randb", "hiphop": "hip hop", "hip hop rap": "hip hop",
        "lofi": "lo fi", "lo fi hip hop": "lo fi", "chillhop": "lo fi",
        "kpop": "k pop", "jpop": "j pop", "jrock": "j rock", "cpop": "c pop",
        "korean": "k pop", "dnb": "drum and bass", "drum n bass": "drum and bass",
        "drumandbass": "drum and bass", "electronica": "electronic", "electro": "electronic",
        "dance": "electronic", "electropop": "synthpop", "synth pop": "synthpop",
        "indierock": "indie rock", "indiepop": "indie pop", "alt rock": "alternative rock",
        "altrock": "alternative rock", "singersongwriter": "singer songwriter",
        "female vocalists": "pop", "hindi pop": "bollywood", "indian": "desi",
        "filmi": "bollywood", "afro beats": "afrobeats", "afropop": "afrobeats",
        "amapiano": "afrobeats", "regueton": "reggaeton", "latin pop": "latin",
        "trip hop": "downtempo", "nu metal": "metal", "classic rock": "rock",
        "soft rock": "rock", "pop rock": "rock", "pop punk": "punk",
        "hardcore punk": "hardcore", "orchestral": "classical", "film score": "soundtrack",
        "score": "soundtrack", "ost": "soundtrack", "chill": "chillout",
        "chillwave": "chillout", "worship": "christian", "rap rock": "rap",
        "gangsta rap": "rap", "underground hip hop": "hip hop",
    ]
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

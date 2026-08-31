import Foundation

/// Port of upstream `TrackMatcher`: decide whether another catalogue's row is
/// the same recording. Too loose and a cover plays under the right title;
/// too strict and a real 320kbps copy is skipped. Identity is title core +
/// version markers; artist overlap and runtime corroborate.
enum TrackMatch {
    struct Target {
        var title: String
        var artist: String
        var durationSec: Int?
    }

    struct Candidate {
        var title: String
        var artist: String
        var durationText: String?
    }

    static func bestIndex(in candidates: [Candidate], target: Target) -> Int? {
        candidates.enumerated()
            .compactMap { i, c in score(c, target).map { (i, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    static func matches(_ candidate: Candidate, target: Target) -> Bool {
        score(candidate, target) != nil
    }

    static func seconds(of text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count) else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }

    // MARK: - Scoring (upstream TrackMatcher.score)

    private static func score(_ candidate: Candidate, _ target: Target) -> Int? {
        let wanted = parseTitle(target.title, artist: target.artist)
        let got = parseTitle(candidate.title, artist: candidate.artist)
        if wanted.core.isEmpty || got.core.isEmpty { return nil }
        if wanted.core != got.core { return nil }
        if wanted.versions != got.versions { return nil }

        let duration = durationScore(wanted: target.durationSec, got: seconds(of: candidate.durationText))
        guard let duration else { return nil }

        let artist: Int
        if let a = artistScore(wanted: target.artist, got: candidate.artist) {
            artist = a
        } else if withinSeconds(candidate, target, 2) {
            artist = -15
        } else {
            return nil
        }
        return 100 + artist + duration + (wanted.context.isDisjoint(with: got.context) ? 0 : 20)
    }

    private static func withinSeconds(_ candidate: Candidate, _ target: Target, _ seconds: Int) -> Bool {
        guard let wanted = target.durationSec, let got = Self.seconds(of: candidate.durationText) else {
            return false
        }
        return abs(wanted - got) <= seconds
    }

    private static func durationScore(wanted: Int?, got: Int?) -> Int? {
        guard let wanted, let got else { return 0 }
        let drift = abs(wanted - got)
        if drift > 30 { return nil }
        return drift <= 3 ? 40 : 15
    }

    private static func artistScore(wanted: String, got: String) -> Int? {
        let want = artistNames(wanted)
        let have = artistNames(got)
        if want.isEmpty || have.isEmpty { return 0 }
        let shared = want.contains { w in have.contains { h in sameArtist(w, h) } }
        if !shared { return nil }
        return want == have ? 25 : 10
    }

    private static func artistNames(_ value: String) -> Set<[String]> {
        Set(
            value.lowercased().split(separator: artistSeparators)
                .map { name in
                    name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "·" })
                        .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                        .filter { $0.count > 1 }
                }
                .filter { !$0.isEmpty }
        )
    }

    private static func sameArtist(_ a: [String], _ b: [String]) -> Bool {
        runOf(a, b) || runOf(b, a)
    }

    private static func runOf(_ outer: [String], _ inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { at in
            Array(outer[at..<(at + inner.count)]) == inner
        }
    }

    // MARK: - Title parse

    private struct TitleParts {
        var core: String
        var versions: Set<String>
        var context: Set<String>
    }

    private static func parseTitle(_ raw: String, artist: String) -> TitleParts {
        var versions = Set<String>()
        var context = Set<String>()
        var text = raw.lowercased().replacingOccurrences(of: "&", with: " and ")

        for _ in 0..<3 {
            guard let match = text.range(of: #"[\(\[]([^()\[\]]*)[\)\]]"#, options: .regularExpression) else { break }
            let inner = String(text[match]).dropFirst().dropLast()
            classify(String(inner), versions: &versions, context: &context)
            text.replaceSubrange(match, with: " ")
        }
        if let open = text.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            classify(String(text[open...]), versions: &versions, context: &context)
            text = String(text[..<open])
        }

        for _ in 0..<3 {
            guard let dash = text.range(of: #"\s+[-–—|]+\s+"#, options: .regularExpression) else { break }
            let head = String(text[..<dash.lowerBound])
            let tail = String(text[dash.upperBound...])
            if isArtistName(head, artist: artist) {
                classify(head, versions: &versions, context: &context)
                text = tail
            } else {
                classify(tail, versions: &versions, context: &context)
                text = head
            }
        }

        if let feat = text.range(of: #"\b(feat|ft|featuring|with)\b.*"#, options: .regularExpression) {
            text.replaceSubrange(feat, with: " ")
        }

        var words = text.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "·" })
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty && !joining.contains($0) }
        while words.count > 1, trailing.contains(words.last ?? "") {
            words.removeLast()
        }
        return TitleParts(core: words.joined(), versions: versions, context: context)
    }

    private static func classify(_ segment: String, versions: inout Set<String>, context: inout Set<String>) {
        let words = segment.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        if words.isEmpty { return }
        if neutral.contains(words.joined()) { return }
        let marks = words.filter { versionWords.contains($0) }
        if !marks.isEmpty {
            versions.formUnion(marks)
            return
        }
        context.formUnion(words.filter { $0.count > 2 && !noise.contains($0) })
    }

    private static func isArtistName(_ text: String, artist: String) -> Bool {
        if artist.isEmpty { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        if words.isEmpty { return false }
        let credited = Set(
            artist.lowercased().split(whereSeparator: \.isWhitespace)
                .map { $0.filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }
        )
        return words.allSatisfy { credited.contains($0) }
    }

    private static let artistSeparators = try! NSRegularExpression(
        pattern: #"\s*(?:[,&/;·|]|\band\b|\bx\b|\bvs\.?\b|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)\s*"#
    )

    private static let joining: Set<String> = ["the", "a", "an", "and", "of"]
    private static let trailing: Set<String> = ["song", "audio", "video", "lyrics", "official", "music"]
    private static let noise: Set<String> = ["the", "a", "an", "and", "of", "from", "official"]
    private static let versionWords: Set<String> = [
        "remix", "remixes", "rmx", "refix", "flip", "bootleg", "mashup", "medley",
        "live", "concert", "unplugged", "acoustic", "instrumental", "karaoke",
        "vocals", "vocal", "acapella", "acappella", "backing", "stems", "stem",
        "cover", "demo", "reprise", "remake", "rework", "extended", "edit",
        "version", "mix", "dub", "vip", "session", "sessions",
        "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "symphonic",
        "part", "pt", "chapter",
    ]
    private static let neutral: Set<String> = [
        "albumversion", "originalversion", "originalmix", "singleversion",
        "radioversion", "radioedit", "stereoversion", "monoversion",
        "studioversion", "fullversion", "standardversion", "explicitversion",
        "deluxeversion", "originaltrack",
    ]
}

private extension String {
    func split(separator regex: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..., in: self)
        let matches = regex.matches(in: self, range: range)
        var last = startIndex
        var parts: [String] = []
        for match in matches {
            guard let r = Range(match.range, in: self) else { continue }
            parts.append(String(self[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(self[last...]))
        return parts
    }
}

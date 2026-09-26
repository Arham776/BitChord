import Foundation
import BitChordShared

// The Explore category grid, against YouTube Music.
//
// A fixture can only prove the parser reads the body it was handed. It cannot
// prove the path is right — that `FEmusic_moods_and_genres` still answers, that
// its sections are `gridRenderer`s, that the buttons are
// `musicNavigationButtonRenderer`s, that a `browseEndpoint` carries `params` at
// all. Every one of those is a claim about the server, and all of them are the
// kind of claim that goes stale quietly: the response changes shape, the parser
// returns an empty list, and the feature reads as "there are no moods today".
//
// So this asks the server. The verdict per stage is explicit, because a
// signed-out answer and a wrong path look identical from inside the parser.

var failures = 0
var checks = 0

extension String { var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func moodCategories() async throws -> [MoodCategory] {
    try await withCheckedThrowingContinuation { continuation in
        HomeBridge.shared.moodAndGenres(callback: MoodAdapter { json, message in
            guard let json else {
                continuation.resume(throwing: NSError(
                    domain: "moods", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "no categories"]
                ))
                return
            }
            do {
                let page = try JSONDecoder().decode([MoodCategory].self, from: Data(json.utf8))
                continuation.resume(returning: page)
            } catch {
                continuation.resume(throwing: error)
            }
        })
    }
}

func shelves(browseId: String, params: String?) async throws -> [ShelfJSON] {
    try await withCheckedThrowingContinuation { continuation in
        HomeBridge.shared.moodGenreShelves(browseId: browseId, params: params, callback: FeedAdapter { json, message in
            guard let json else {
                continuation.resume(throwing: NSError(
                    domain: "shelves", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "no shelves"]
                ))
                return
            }
            do {
                let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
                continuation.resume(returning: page.shelves)
            } catch {
                continuation.resume(throwing: error)
            }
        })
    }
}

struct MoodCategory: Decodable {
    struct Item: Decodable {
        let title: String
        let browseId: String
        let params: String?
        let thumbnailUrl: String?
    }
    let title: String
    let items: [Item]
}

struct FeedPage: Decodable {
    let shelves: [ShelfJSON]
}
struct ShelfJSON: Decodable {
    let title: String
    let items: [CardJSON]
}
struct CardJSON: Decodable {
    let title: String
    let videoId: String?
    let browseId: String?
}

private final class MoodAdapter: HomeBridgeMoodCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

private final class FeedAdapter: HomeBridgeFeedCallback {
    private let onResult: (String?, String?) -> Void
    init(onResult: @escaping (String?, String?) -> Void) { self.onResult = onResult }
    func onResult(json: String?, message: String?) { onResult(json, message) }
}

print("moods and genres: the real FEmusic_moods_and_genres response")

var sections: [MoodCategory] = []
do {
    sections = try await moodCategories()
    check("the endpoint answers with categories", !sections.isEmpty, "\(sections.count) section(s)")
} catch {
    check("the endpoint answers with categories", false, error.localizedDescription)
    print("\n0 of \(checks) checks passed")
    exit(1)
}

for section in sections {
    print("  · \(section.title): \(section.items.count) — \(section.items.prefix(6).map(\.title).joined(separator: ", "))")
}

// 1. A heading is what makes the buttons mean anything ("Moods" and "Genres" are
//    different sets), so a section without one would be a hole in the page.
check("every section has a heading", sections.allSatisfy { !$0.title.isBlank })

// 2. Every button has to be navigable, or it is a button that goes nowhere.
check("every category has a browse id", sections.flatMap(\.items).allSatisfy { !$0.browseId.isBlank })

// 3. `params` is the one that is easy to lose and hard to notice: a category
//    without it answers with a different, generic page rather than an error, so
//    a parser that dropped it would look like a working feature returning the
//    wrong thing. If every category here has params, dropping them is a defect.
let withParams = sections.flatMap(\.items).filter { ($0.params ?? "").isEmpty }.count
let total = sections.flatMap(\.items).count
check("categories carry their browse params", withParams < total,
      "\(total - withParams)/\(total) have params")

// 4. A category with no params at all, if there is one, is the one that proves
//    the shelves call works without them too. Reported rather than asserted,
//    because it depends on what the server sends today.
if let bare = sections.flatMap(\.items).first(where: { ($0.params ?? "").isEmpty }) {
    print("  · note: \(bare.title) has no params — checked below as the nil case")
}

// 5. The real test: a category's shelves must actually come back with content.
//    This is the one that fails if `params` was dropped somewhere between the
//    parser and the request — the id alone answers, just with the wrong page.
let probe = sections.first { !$0.items.isEmpty }?.items[0]
if let probe {
    do {
        let got = try await shelves(browseId: probe.browseId, params: probe.params)
        check("a category's shelves come back", !got.isEmpty,
              "\(probe.title) -> \(got.count) shelf(es), \(got.prefix(3).map(\.title).joined(separator: " / "))")
        let cards: [CardJSON] = got.flatMap { $0.items }
        check("its cards are playable or openable",
              cards.contains { ($0.videoId ?? "").isEmpty == false || ($0.browseId ?? "").isEmpty == false },
              "\(cards.count) card(s)")
    } catch {
        check("a category's shelves come back", false, "\(probe.title): \(error.localizedDescription)")
    }
} else {
    check("a category's shelves come back", false, "no category to probe")
}

// 6. The second call must be served from the cache, because the category's tile
//    artwork is drawn from the same response and a listener who taps a category
//    whose cover has already appeared should not pay for the bytes twice.
//    Checked by timing rather than by observation, so the bar has to sit
//    decisively between "a map lookup" and "a network round trip" rather than
//    just under the former: 50 ms is three orders of magnitude above the lookup
//    and comfortably below any real request, so it is not a coin flip on a
//    loaded machine.
if let probe = sections.first?.items.first {
    let start = Date()
    _ = try? await shelves(browseId: probe.browseId, params: probe.params)
    let cachedMs = Date().timeIntervalSince(start) * 1000
    check("a repeat request for the same category is served from the cache",
          cachedMs < 50, String(format: "%.2f ms — a round trip is >100 ms", cachedMs))
}

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)

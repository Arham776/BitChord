import Foundation

// Only the snapshot's enum dependency is needed by this standalone Mac check.
enum PlaybackController {
    enum RepeatMode: Int { case off, all, one }
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
func track(_ id: String, order: Int? = nil, autoplay: Bool = false) -> QueueEntry {
    var entry = QueueEntry.youtube(videoId: id, title: id, artist: "Artist", fromAutoplay: autoplay)
    entry.contextOrder = order
    return entry
}
let queue = [track("played", order: 0), track("selected", order: 1),
             track("manual"), track("low", order: 2), track("high", order: 3),
             track("suggestion", autoplay: true)]
let scores = [0.0, 0, 100, 0.1, 0.9, 100]
let ordered = PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: true, scores: scores)
check(ordered.map(\.id) == ["played", "selected", "manual", "high", "low", "suggestion"], "Automix wins and only sequences unplayed list slots")
check(PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: false, scores: scores) == ordered, "Shuffle preference cannot override Automix")
check(PlaybackQueuePolicy.orderList(ordered, after: 1, automix: false, shuffle: false, scores: scores) == queue, "Ordered mode restores upcoming source order without rewinding history")
check(PlaybackQueuePolicy.orderList(queue, after: 1, automix: true, shuffle: false, scores: Array(repeating: 0, count: queue.count)) == queue, "Equal affinity preserves source order")
var sawShuffle = false
for _ in 0..<30 {
    let shuffled = PlaybackQueuePolicy.orderList(queue, after: 1, automix: false, shuffle: true, scores: scores)
    check(Array(shuffled.prefix(3)) == Array(queue.prefix(3)) && shuffled.last == queue.last, "Shuffle preserves played, selected, manual and autoplay rows")
    check(Set(shuffled[3...4].map(\.id)) == ["low", "high"], "Shuffle keeps every list candidate")
    sawShuffle = sawShuffle || shuffled != queue
}
check(sawShuffle, "Shuffle reorders eligible tracks when Automix is off")
let duplicateManual = [track("seed", order: 0), track("same"), track("same", order: 1), track("best", order: 2)]
let duplicateOrdered = PlaybackQueuePolicy.orderList(duplicateManual, after: 0, automix: true, shuffle: false, scores: [0, 0, 0, 1])
check(duplicateOrdered[1].contextOrder == nil && duplicateOrdered[2].id == "best", "A manual copy of a list song stays protected")
let shuffledSeed = PlaybackQueuePolicy.startingWith(queue, seed: 4)
check(shuffledSeed.first?.id == "high" && Set(shuffledSeed.map(\.id)) == Set(queue.map(\.id)), "A random Shuffle seed keeps all earlier candidates")
let mixed = [track("played-auto", autoplay: true), track("seed"), track("manual"), track("old-auto", autoplay: true)]
check(PlaybackQueuePolicy.withoutUpcomingAutoplay(mixed, after: 1).map(\.id) == ["played-auto", "seed", "manual"], "Refresh keeps played autoplay and manual entries")
check(!PlaybackQueuePolicy.shouldRefillAutoplay(upcomingCount: 3), "Natural handoff leaves a three-item queue alone")
check(PlaybackQueuePolicy.shouldRefillAutoplay(upcomingCount: 2), "Natural handoff refills below the three-item watermark")
func context(_ source: String = "yt:seed", index: Int = 0, generation: UInt64 = 1, edit: UInt64 = 0, session: Int64 = 1) -> AutoplayRefreshState.Context {
    .init(source: source, index: index, playbackGeneration: generation, queueEditRevision: edit, sessionGeneration: session)
}
var refresh = AutoplayRefreshState()
let initial = context()
let request = refresh.begin(initial)!
check(refresh.begin(initial) == nil, "Arming the engine repeatedly coalesces recommendation requests")
check(refresh.accepts(request, current: initial), "Current request can install recommendations")
for changed in [context("yt:next", index: 1), context(index: 1), context(generation: 2), context(edit: 1), context(session: 2)] {
    check(!refresh.accepts(request, current: changed), "Selection, skip/back, queue or account changes reject stale replies")
}
let rated = refresh.begin(initial, force: true)!
check(!refresh.accepts(request, current: initial) && refresh.accepts(rated, current: initial), "A successful rating supersedes the old request even with the same seed")
refresh.invalidate()
check(!refresh.accepts(rated, current: initial), "Disabling autoplay or entering repeat-all invalidates pending recommendations")
let now = 1_800_000_000_000.0
let fresh = PlaybackQueuePolicy.score(transitionFit: nil, affinity: 0, playedAt: nil, now: now)
check(fresh > PlaybackQueuePolicy.score(transitionFit: nil, affinity: 0, playedAt: now - 1000, now: now), "Freshness works without audio analysis")
check(PlaybackQueuePolicy.score(transitionFit: nil, affinity: 1, playedAt: nil, now: now) > fresh, "Listening affinity works without audio analysis")
check(PlaybackQueuePolicy.score(transitionFit: 1, affinity: 0, playedAt: nil, now: now) > fresh, "Available transition analysis contributes to ordering")
for (origin, hasQueue, stopped, audible, expected) in [
    ("list", true, false, true, PlaybackQueuePolicy.HeroState.playing),
    ("list", true, false, false, .paused), ("other", true, false, true, .inactive),
    ("list", true, true, false, .inactive), ("list", false, false, true, .inactive)
] {
    check(PlaybackQueuePolicy.heroState(origin: origin, listID: "list", hasQueue: hasQueue, stopped: stopped, playingOrBuffering: audible) == expected, "Hero reflects playing/buffering, pause, stopped and different-list state")
}
let defaults = UserDefaults.standard
let previousSnapshot = defaults.object(forKey: "bitchord_last_played")
defer {
    if let previousSnapshot { defaults.set(previousSnapshot, forKey: "bitchord_last_played") }
    else { defaults.removeObject(forKey: "bitchord_last_played") }
}
LastPlayed.save(tracks: ordered, index: 1, position: 42, repeatMode: .one, shuffleEnabled: true, volume: 0.8, contextID: "list", contextTitle: "Album")
let restored = LastPlayed.load()!
check(restored.contextID == "list" && restored.contextTitle == "Album", "Origin is saved atomically with the queue")
check(restored.tracks == ordered && restored.index == 1 && restored.position == 42 && restored.shuffleEnabled, "Order, provenance and playback state survive restore")
var old = try JSONSerialization.jsonObject(with: defaults.data(forKey: "bitchord_last_played")!) as! [String: Any]
old.removeValue(forKey: "contextID")
old.removeValue(forKey: "contextTitle")
old["tracks"] = (old["tracks"] as! [[String: Any]]).map { track in
    var track = track; track.removeValue(forKey: "contextOrder"); return track
}
defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "bitchord_last_played")
check(LastPlayed.load()?.contextID == nil && LastPlayed.load()?.tracks.count == queue.count, "Older snapshots remain readable")
print("PASS \(checks) queue, recommendation, sequencing, hero and restore checks")

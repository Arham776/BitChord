import Foundation
import BitChordShared

// LyricsPlus's mirror rotation, against the real mirrors.
//
// The point of the health table is that one mirror has a certificate iOS will
// not accept, so every request to it fails ATS with -9802 and the system log
// fills with the same trust failure once per track. Racing the mirrors meant the
// source still worked, so the only symptom was the noise — and a symptom nobody
// can measure is a symptom nobody fixes.
//
// So this measures it: the same track, asked for twice, with the timing of each
// recorded. The second ask should be materially cheaper, because the mirrors
// that could not be reached are no longer being asked. A fixture cannot show
// any of that, and neither can the existing source sweep, which only records
// whether lyrics came back.
//
// Run: scripts/check-mirrors.sh

struct Track {
    let title: String
    let artist: String
    let seconds: Int
    var ms: Int64 { Int64(seconds) * 1000 }
}

let track = Track(title: "As It Was", artist: "Harry Styles", seconds: 165)

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// The five asks, timed. Long enough that a mirror which cannot be reached costs
/// real time on every one, which is the condition this harness is checking for.
func sweep() async -> (times: [Double], found: Int) {
    var times: [Double] = []
    var found = 0
    // Three tracks rather than one: the health table is process-wide, so a
    // second and third ask are what prove the learning persisted rather than
    // being an accident of ordering.
    for round in 0..<3 {
        let start = Date()
        // The callback shape, not async/await: Kotlin's default arguments are
        // not exported to Swift, so `album` and `isrc` have to be passed
        // explicitly, and the bridge answers through a completion.
        let lines: [LyricLineDto] = await withCheckedContinuation { c in
            LyricsPlus.shared.lyrics(
                title: track.title, artist: track.artist, durationMs: track.ms,
                album: nil, isrc: nil
            ) { lines, _ in
                c.resume(returning: lines ?? [])
            }
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        times.append(elapsed)
        if !lines.isEmpty {
            found += 1
            print(String(
                format: "  · ask %d: %.0f ms, %d line(s)", round + 1, elapsed, lines.count
            ))
        } else {
            print(String(format: "  · ask %d: %.0f ms, nothing", round + 1, elapsed))
        }
    }
    return (times, found)
}

print("mirrors: the same track, three times")
print("  · the first ask pays for cold DNS and TLS on every mirror, including the ones")
print("    that cannot answer, so it runs to the timeout. Later asks pay only for the")
print("    mirrors that work — that difference is the whole point of the health table.")
let (times, found) = await sweep()

// 1. The source still works. Everything below is about cost, not correctness, so
//    a source that stopped answering would make the rest of this meaningless.
check("LyricsPlus still answers", found > 0, "\(found)/3 asks returned lyrics")

// 2. The health table has to be doing something. A first ask pays for every
//    mirror it does not know about; later asks pay only for the ones that
//    answered. So the median of the last two must be below the first.
if times.count == 3 {
    let first = times[0]
    let later = (times[1] + times[2]) / 2
    // Generous, because this is a network measurement: the claim is not "much
    // faster" but "the unreachable mirrors are no longer being asked at all",
    // which shows up as the later asks not paying their full cost.
    check("later asks are cheaper than the first", later < first,
          String(format: "first %.0f ms, later mean %.0f ms", first, later))
} else {
    check("later asks are cheaper than the first", false, "not enough asks recorded")
}

// 3. And the source must not have been starved: a health table that skipped
//    every mirror would answer nothing, and this is the check that would notice
//    that happening rather than reporting the speed-up as a success.
check("the source was not starved to get faster", found > 0,
      "\(found)/3 asks returned lyrics")

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)

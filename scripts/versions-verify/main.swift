import Foundation
import BitChordShared

// The revert-to-original pin, through the real Swift→Kotlin seam.
//
// The codec has twelve tests in shared/commonTest, and they are worth having —
// but every one of them runs inside Kotlin. A codec can be correct and the
// *call site* still wrong: a mistyped argument label, an optional the seam hands
// over as something other than nil, a write that goes somewhere the reader does
// not look. Only crossing the boundary can show that.
//
// It also checks the write-through, because "it is pinned in memory" and "it will
// still be pinned after the app restarts" are different claims and the second one
// is the entire reason this feature is a store rather than a set in a controller.

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

let settings = PlatformSettings.shared
let store = "original_version_pins"
let real = "dQw4w9WgXcQ"
let other = "oHg5SJYRHA0"

// Start from a known state, and put it back at the end — this harness writes to
// the same defaults the app reads.
let saved = settings.getString(key: store, default: "")
defer {
    settings.putString(key: store, value: saved)
    for id in [real, other] { OriginalVersion.shared.unpin(videoId: id) }
}
settings.putString(key: store, value: "")
OriginalVersion.shared.unpin(videoId: real)
OriginalVersion.shared.unpin(videoId: other)

// 1. Nothing is pinned to begin with.
check("a fresh id is not pinned",
      !OriginalVersion.shared.isPinned(videoId: real))

// 2. Pin, then read back through the same seam.
OriginalVersion.shared.pin(videoId: real)
check("a pinned id reads back as pinned",
      OriginalVersion.shared.isPinned(videoId: real))
check("pinning one id does not pin another",
      !OriginalVersion.shared.isPinned(videoId: other))

// 3. The write-through: the pin has to be in the store, not only in memory.
//    This is what survives process death, which is the case a purely in-memory
//    set would miss and the one most likely to be noticed, because the queue is
//    restored from disk.
let written = settings.getString(key: store, default: "")
check("the pin reached the store", written == real, "stored: \(written.isEmpty ? "<empty>" : written)")

// 4. The set the menu reads has to contain it too — that is a different accessor
//    from `isPinned`, and a menu offering the wrong row is the failure here.
let ids = OriginalVersion.shared.pinnedIds()
check("the menu's pin list contains it", ids.contains(real), "\(ids.sorted())")

// 5. Pinning twice is one line, not two. A store that grew a duplicate per tap
//    would still read back correctly, so only the stored form shows this.
OriginalVersion.shared.pin(videoId: real)
let twice = settings.getString(key: store, default: "")
check("pinning twice stores one entry", twice == real, "stored: \(twice)")

// 6. A second id joins it, and the stored form is what `encode` promises.
OriginalVersion.shared.pin(videoId: other)
let both = settings.getString(key: store, default: "")
check("two pins store as two ordered lines",
      both == "\(real)\n\(other)" || both == "\(other)\n\(real)", "stored: \(both.replacingOccurrences(of: "\n", with: " | "))")

// 7. An empty id must not become a pin. `isPinned` is asked about ids that came
//    from a queue entry, and a row with no YouTube id behind it arrives here as
//    an empty string often enough to matter.
OriginalVersion.shared.pin(videoId: "")
check("an empty id does not become a pin",
      !OriginalVersion.shared.isPinned(videoId: ""),
      "pins: \(OriginalVersion.shared.pinnedIds().sorted())")

// 8. The nil call. This is the one a Kotlin test structurally cannot make: the
//    seam has to hand a missing id over as nil rather than as a crash or a
//    literal "null" string, which would pin a track named "null".
check("nil is not pinned", !OriginalVersion.shared.isPinned(videoId: nil))
check("nil did not become a pin named null",
      !OriginalVersion.shared.isPinned(videoId: "null"),
      "pins: \(OriginalVersion.shared.pinnedIds().sorted())")

// 9. Unpinning is the only way back, and it has to clear the store too.
OriginalVersion.shared.unpin(videoId: real)
check("an unpinned id reads back as not pinned",
      !OriginalVersion.shared.isPinned(videoId: real))
check("the unpinned id left the store",
      !settings.getString(key: store, default: "").contains(real),
      "stored: \(settings.getString(key: store, default: "").replacingOccurrences(of: "\n", with: " | "))")

// 10. Unpinning something that was never pinned changes nothing and, more
//     importantly, does not wipe the other pins.
OriginalVersion.shared.unpin(videoId: "9bZkp7q19f0")
check("unpinning an absent id leaves the others alone",
      OriginalVersion.shared.isPinned(videoId: other),
      "pins: \(OriginalVersion.shared.pinnedIds().sorted())")

// 11. The store is read once, at first use, and the live set is then the truth —
//     upstream's `StateFlow` behaves the same way. A write to the store from
//     behind the object's back is therefore not observed, and that is a
//     contract rather than a gap: the app only ever writes through `pin`, and a
//     resolution already in flight has to see the pins as they are rather than
//     re-reading the store mid-decision. Stated here because it is the one
//     behaviour a caller could otherwise be surprised by.
OriginalVersion.shared.unpin(videoId: other)
settings.putString(key: store, value: "\r\n  \(real)  \n\n")
check("the store is read once, not per query",
      !OriginalVersion.shared.isPinned(videoId: real),
      "the live set is authoritative once loaded")

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)

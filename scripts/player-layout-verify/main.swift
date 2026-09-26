import CoreGraphics
import Foundation

// The player's window-shape rules, from the app's own source.
//
// Each check names the mistake it exists to catch. "It looks right" is not
// something this file can conclude on its own — these are thresholds, and a
// threshold is only correct relative to the case on either side of it.

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

func landscape(_ label: String, _ width: CGFloat, _ height: CGFloat, _ want: Bool) {
    let got = PlayerLayout.takesLandscapeShape(width: width, height: height)
    check(
        "\(label) (\(Int(width))×\(Int(height))) is \(want ? "landscape" : "portrait")",
        got == want
    )
}

print("player layout: which shape a window takes")

// ---- the shape test -------------------------------------------------------

// A phone upright. The shape the portrait player was drawn for.
landscape("a phone upright", 393, 852, false)

// A phone on its side. Wide and short, and the two columns work.
landscape("a phone on its side", 852, 393, true)

// A tablet upright. As wide as a phone on its side, and still portrait: this is
// the case the heuristic exists for, and a device-class test would get it wrong.
landscape("a tablet upright", 820, 1180, false)

// A tablet on its side.
landscape("a tablet on its side", 1180, 820, true)

// A Mac window.
landscape("a Mac window", 1440, 900, true)

// A square window is neither shape, and the portrait player is the one that was
// drawn to be looked at. `>` rather than `>=` is the whole of that.
landscape("a square window", 600, 600, false)

// ---- the floor ------------------------------------------------------------

// One point either side of the floor, because a threshold is only correct
// relative to what it excludes.
landscape("just below the floor", PlayerLayout.landscapeMinWidth - 1, 300, false)
landscape("exactly the floor", PlayerLayout.landscapeMinWidth, 300, true)
landscape("just above the floor", PlayerLayout.landscapeMinWidth + 1, 300, true)

// The floor only applies to width. A narrow window that is *shorter* than it is
// wide is still landscape-shaped, and the floor is there for the columns' sake
// rather than the window's.
landscape("narrow but wider than tall", 300, 200, false)

// ---- compactness ----------------------------------------------------------

// A short landscape window needs the compact treatment: less gutter, or the row
// under the sleeve gets pushed off the bottom.
check(
    "a phone on its side is compact",
    PlayerLayout.isCompactLandscape(width: 852, height: 393)
)
check(
    "a Mac window is not compact",
    !PlayerLayout.isCompactLandscape(width: 1440, height: 900)
)
check(
    "a window one point below the compact height is compact",
    PlayerLayout.isCompactLandscape(width: 900, height: PlayerLayout.landscapeCompactHeight - 1)
)
check(
    "a window exactly at the compact height is not",
    !PlayerLayout.isCompactLandscape(width: 900, height: PlayerLayout.landscapeCompactHeight)
)

// The compact gutter is genuinely smaller, and both are positive — a negative
// gutter would overlap the two columns.
check("compact uses a smaller gutter",
      PlayerLayout.gutter(compact: true) < PlayerLayout.gutter(compact: false),
      "\(Int(PlayerLayout.gutter(compact: true))) < \(Int(PlayerLayout.gutter(compact: false)))")
check("both gutters are positive",
      PlayerLayout.gutter(compact: true) > 0 && PlayerLayout.gutter(compact: false) > 0)

// The columns stop growing past the ceiling, or a very wide window opens a gulf
// between them.
check("the landscape player has a width ceiling", PlayerLayout.landscapeMaxWidth > 0)
check("the ceiling is wider than the floor",
      PlayerLayout.landscapeMaxWidth > PlayerLayout.landscapeMinWidth,
      "\(Int(PlayerLayout.landscapeMaxWidth)) > \(Int(PlayerLayout.landscapeMinWidth))")

// ---- the portrait artwork -------------------------------------------------

// On a tall phone the artwork is as large as the width allows.
let tall = PlayerLayout.portraitArtworkSide(stageWidth: 393, stageHeight: 600)
check("a tall stage fits an artwork to its width", abs(tall - (393 - 48)) < 0.5,
      "\(Int(tall)) of \(393 - 48) available")

// On a short stage the height is what runs out, and the artwork shrinks rather
// than pushing the deck off the bottom.
let short = PlayerLayout.portraitArtworkSide(stageWidth: 393, stageHeight: 200)
check("a short stage fits the artwork to its height", abs(short - (200 - 20)) < 0.5,
      "\(Int(short)) of \(200 - 20) available")
check("a short stage shrinks the artwork", short < tall,
      "\(Int(short)) < \(Int(tall))")

// The square it returns is a square: never wider than the stage allows.
check("the artwork is never wider than its stage",
      PlayerLayout.portraitArtworkSide(stageWidth: 300, stageHeight: 900) <= 300)
check("the artwork is never taller than its stage",
      PlayerLayout.portraitArtworkSide(stageWidth: 900, stageHeight: 100) <= 100)

// A stage too short to hold a square shows a small one rather than none, and
// never a *larger* one than the collapsed sleeve — otherwise a squeezed stage
// would jump up as it was squeezed.
let squeezed = PlayerLayout.portraitArtworkSide(stageWidth: 200, stageHeight: 30)
check("a squeezed stage still shows an artwork", squeezed > 0, "\(Int(squeezed))")
check("a squeezed stage does not show a bigger artwork than the collapsed one",
      squeezed <= PlayerLayout.sleeveCollapsedSide,
      "\(Int(squeezed)) <= \(Int(PlayerLayout.sleeveCollapsedSide))")

// The collapsed sleeve is a target, not a decoration.
check("the collapsed sleeve is a usable target",
      PlayerLayout.sleeveCollapsedSide >= 44,
      "\(Int(PlayerLayout.sleeveCollapsedSide))pt — 44 is Apple's minimum")

// Nothing is negative for a window that exists.
for (w, h) in [(CGFloat(1), CGFloat(1)), (100, 50), (3000, 2000), (5000, 10)] {
    let side = PlayerLayout.portraitArtworkSide(stageWidth: w, stageHeight: h)
    check("no negative artwork for \(Int(w))×\(Int(h))", side > 0, "\(Int(side))")
}

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)

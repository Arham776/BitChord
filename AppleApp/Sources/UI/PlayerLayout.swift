import CoreGraphics
import Foundation

/// The player's window-shape rules.
///
/// Upstream keeps these apart from the screen for the same reason: they are
/// questions about a window, and every one of them has an edge case that is
/// easier to get wrong than to describe. `FrameHeuristics.kt` is where upstream
/// puts the same kind of thing, and a screen that asked "is this an iPad" would
/// be asking the wrong question entirely.
///
/// ## Why proportions and not device class
///
/// The two-column landscape player is a *shape*, not a size. A tablet held
/// upright can be as wide as a phone held sideways, and it must still get the
/// portrait player — the tall column is the shape the portrait player was drawn
/// for, and putting two columns in an upright tablet leaves both of them too
/// narrow to hold what they are given. So the only question asked is whether the
/// window is wider than it is tall, plus a floor below which the columns stop
/// working.
enum PlayerLayout {

    // ---- the landscape shape -----------------------------------------------

    /// A window narrower than this takes the portrait player even when it is wider
    /// than it is tall. Upstream's `LANDSCAPE_PLAYER_MIN_WIDTH`.
    ///
    /// The floor is about the columns rather than the device: below it, half the
    /// width cannot hold a square sleeve and a row of pane toggles with any
    /// gutter left over.
    static let landscapeMinWidth: CGFloat = 560

    /// A landscape window shorter than this is compact: less gutter, less space
    /// between the sleeve and the row under it, and no bottom breathing room.
    /// Upstream's `LANDSCAPE_COMPACT_HEIGHT`.
    static let landscapeCompactHeight: CGFloat = 440

    /// How wide the two columns together are ever allowed to get, centred in
    /// whatever window there is. Upstream's `LANDSCAPE_PLAYER_MAX_WIDTH`.
    ///
    /// Without a ceiling, a very wide window stretches both columns and opens a
    /// gulf down the middle — the player reads as two half-screens rather than one
    /// screen with something in it.
    static let landscapeMaxWidth: CGFloat = 1100

    /// Gutter either side of the columns, in a landscape window.
    static let landscapeGutter: CGFloat = 30
    static let landscapeGutterCompact: CGFloat = 20

    /// Whether the player takes its landscape shape: the sleeve and the pane row
    /// in the left column, the credits and transport or the lyrics or the queue
    /// in the right.
    ///
    /// `>` and not `>=` for the first comparison, so a square window takes the
    /// portrait player. A square is neither shape, and the portrait player is the
    /// one that was drawn to be looked at.
    static func takesLandscapeShape(width: CGFloat, height: CGFloat) -> Bool {
        width > height && width >= landscapeMinWidth
    }

    /// Whether a landscape window is short enough to need the compact treatment.
    static func isCompactLandscape(width: CGFloat, height: CGFloat) -> Bool {
        height < landscapeCompactHeight
    }

    /// The gutter for this window.
    static func gutter(compact: Bool) -> CGFloat {
        compact ? landscapeGutterCompact : landscapeGutter
    }

    // ---- the portrait stage ------------------------------------------------

    /// The collapsed artwork's side, when a panel is up in the portrait player.
    ///
    /// Big enough to be a comfortable target, small enough that the panel below it
    /// is still the screen rather than a strip under a picture.
    static let sleeveCollapsedSide: CGFloat = 56

    /// The largest square artwork that fits a portrait stage, given the gutters the
    /// player keeps around it.
    ///
    /// Floored rather than allowed to reach zero: a stage too short to hold a
    /// square should show a small one, not disappear. The floor is also below the
    /// collapsed size, so a nearly-collapsed stage does not jump *up* as it is
    /// squeezed.
    static func portraitArtworkSide(stageWidth: CGFloat, stageHeight: CGFloat) -> CGFloat {
        let fitted = min(stageWidth - 48, stageHeight - 20)
        return max(sleeveCollapsedSide, fitted)
    }
}

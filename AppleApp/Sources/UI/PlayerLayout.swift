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
    /// Tall non-Spotify clips fit within the player, aligned at its top.
    static func containedCanvasSize(bounds: CGSize, aspect: CGFloat) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0, aspect.isFinite else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }


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

    // ---- full-bleed artwork --------------------------------------------------

    /// The widest a player given the whole window can be and still run its
    /// artwork edge to edge. Upstream's `PLAYER_MAX_WIDTH + PLAYER_GUTTER * 2`.
    static let fullBleedMaxWidth: CGFloat = 620

    /// The width from which the player counts as tablet-sized. Upstream's
    /// `TABLET_PLAYER_MIN_WIDTH`: a 360pt page beside a 340pt pane.
    static let tabletMinWidth: CGFloat = 700

    /// Whether this window can use the full-bleed art treatment: phone-width
    /// windows use it as their main-player shape, while tablet-sized windows
    /// can opt into it. Mirrors upstream `fullBleedArtworkAvailable`.
    static func fullBleedArtworkAvailable(width: CGFloat) -> Bool {
        width <= fullBleedMaxWidth || width >= tabletMinWidth
    }

    /// The artwork setting applies at phone width too, as it does upstream.
    static func usesFullBleedArtwork(width: CGFloat, preferenceEnabled: Bool) -> Bool {
        preferenceEnabled && fullBleedArtworkAvailable(width: width)
    }

    // ---- iPad panel drawer ---------------------------------------------------

    /// Whether an open lyrics/queue panel presents as a bottom drawer: iPad
    /// portrait — regular width of at least 560pt in a portrait shape — where
    /// a full-height panel would leave the collapsed sleeve floating in a tall
    /// column. Mirrors upstream `PlayerDrawer`'s tablet treatment.
    static func presentsPanelDrawer(width: CGFloat, height: CGFloat) -> Bool {
        width >= landscapeMinWidth && height > width
    }
}

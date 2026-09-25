import SwiftUI

/// Design tokens and system-setting-aware behaviour, ported from upstream
/// `ui/theme/Theme.kt` (UI spec §7).
///
/// Upstream keeps its colours, spacings and type ramp in one place and every
/// screen reads from it. This port had no equivalent — colours and metrics were
/// hardcoded per view — which is why small drifts accumulated (a fixed 32pt
/// title here, a 26pt monospaced one there) and why nothing honoured the system
/// accessibility settings as a set.
///
/// Three things live here rather than being scattered through the views:
///
///  - **Tokens.** Spacing and radii as a scale, so a 4pt rhythm is a decision
///    rather than an accident.
///  - **[Motion].** Every animation in the app routes through here so Reduce
///    Motion is honoured *everywhere* from one place. Before this, the system
///    setting had no effect on the shimmer, the mix sheen, the sleeve spring or
///    the lyrics sweep.
///  - **[Materials].** Every blur routes through here so Reduce Transparency is
///    honoured everywhere too. The app leans hard on `.ultraThinMaterial` for
///    the playback pill and the Replay overlay, and without this those are
///    unreadable for anyone who turns transparency off.
enum Theme {
    /// The app's tint. Matches the artwork-derived accent the player uses, so
    /// chrome and content agree rather than fighting.
    static let accent = Color.accentColor

    // MARK: - Metrics

    enum Metrics {
        /// 4pt rhythm. `s`, `m`, `l`, `xl` read better at call sites than
        /// numbers, and a scale is what keeps padding consistent between screens
        /// that were written months apart.
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 16
        static let xl: CGFloat = 24

        /// Continuous corners, per the UI spec's artwork rule.
        static let artworkRadius: CGFloat = 6
        static let rowRadius: CGFloat = 8
        static let cardRadius: CGFloat = 14

        /// Apple's minimum comfortable hit target. Enforced on every custom
        /// control so nothing is smaller than a fingertip.
        static let minHitTarget: CGFloat = 32

        /// Row metrics, used by `SongRow` and the feed shelves so a row is the
        /// same height everywhere it appears.
        static let rowArt: CGFloat = 44
        static let shelfCard: CGFloat = 160
        static let gridCard: CGFloat = 140
        static let headerArt: CGFloat = 170
    }
}

/// Animation helpers that respect Reduce Motion.
///
/// The rule: with Reduce Motion on, an animation becomes either nothing or a
/// short cross-fade, and a looping animation becomes a static state. Motion that
/// is *feedback* (a scrubber following a drag) still has to track the finger —
/// that is the control, not decoration — so it keeps a response rather than a
/// spring.
///
/// `reduceMotion` is passed in rather than read from the environment here,
/// because an `enum` cannot hold an `@Environment` property. Call sites read
/// `\.accessibilityReduceMotion` into a local and hand it to these.
enum Motion {
    /// A one-shot animation, shortened under Reduce Motion rather than removed.
    ///
    /// Removed entirely would make state changes snap, which reads as a bug
    /// rather than as an accommodation. A short fade keeps the change legible
    /// while removing the travel.
    static func once(
        _ reduceMotion: Bool,
        duration: Double = 0.25,
        curve: Animation = .easeInOut
    ) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : curve
    }

    /// A looping animation, or `nil` under Reduce Motion.
    ///
    /// `nil` is the point: returning a shorter duration still leaves something
    /// pulsing, and a skeleton that changes brightness is still motion to
    /// someone who has asked for none. Returning nil means the modifier is not
    /// applied at all.
    static func loop(
        _ reduceMotion: Bool,
        duration: Double,
        curve: Animation = .easeInOut
    ) -> Animation? {
        reduceMotion ? nil : curve
            .repeatForever(autoreverses: true)
            .speed(1.0 / max(duration, 0.01))
    }
}

/// Blur surfaces that respect Reduce Transparency.
///
/// Under Reduce Transparency the material is replaced with an opaque fill that
/// keeps the same contrast, rather than dropped — a clear background behind text
/// over artwork is unreadable, which is the opposite of what the setting asks
/// for. The app leans hard on blur for the playback pill and the Replay overlay,
/// so this is load-bearing rather than cosmetic.
///
/// Exposed as modifiers rather than as returned views because the materials are
/// `ShapeStyle`s, not views; a `ViewModifier` is the shape that actually composes.
struct ChromeBackground: ViewModifier {
    enum Weight {
        /// The playback pill and the Replay overlay.
        case thin
        /// Sheets and popovers.
        case regular
    }

    let weight: Weight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                Rectangle().fill(opaque)
            } else {
                switch weight {
                case .thin: Rectangle().fill(.ultraThinMaterial)
                case .regular: Rectangle().fill(.regularMaterial)
                }
            }
        }
    }

    private var opaque: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor).opacity(0.98)
        #else
        Color(uiColor: .systemBackground).opacity(0.98)
        #endif
    }
}

extension View {
    /// A material-backed surface that becomes opaque under Reduce Transparency.
    func chromeBackground(_ weight: ChromeBackground.Weight = .thin) -> some View {
        modifier(ChromeBackground(weight: weight))
    }
}

// MARK: - Control helpers

extension View {
    /// Guarantees a tappable area of at least `Metrics.minHitTarget`, by
    /// expanding the hit region rather than the visual. Applied to every
    /// transport and toolbar control: an icon drawn at 15pt still needs a 32pt
    /// target to be comfortably pressable.
    func minimumHitTarget(_ size: CGFloat = Theme.Metrics.minHitTarget) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(.rect)
    }

    /// Hides a decorative image from assistive technology.
    ///
    /// Template assets otherwise announce their asset name ("bch-chevron-right"),
    /// which is worse than silence. Controls that *are* the image get a label
    /// instead, via `accessibilityLabel`.
    func decorative() -> some View {
        accessibilityHidden(true)
    }
}

/// A labelled, adjustable representation for the app's custom sliders.
///
/// The playback scrubber and the volume sliders are hand-drawn rather than
/// `Slider` because a native slider cannot show the Automix transition window or
/// the mix sheen behind the playhead. That is a fair trade — but only if the
/// custom control then *behaves* like a slider to a screen reader, which it did
/// not: the scrubber published an `accessibilityValue` with no label and no
/// adjustable action, so a VoiceOver user could not seek at all.
enum AdjustableAccessibility {
    /// Apply label, value and increment/decrement behaviour to a custom slider.
    static func apply<V: View>(
        to view: V,
        label: String,
        value: Double,
        formatted: String,
        increment: Double = 1,
        decrement: Double = 5,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        view
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(formatted)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(value + increment)
                case .decrement: onChange(value - decrement)
                @unknown default: break
                }
            }
    }
}

import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What a touch *meant* — the shape of the buzz is this file's business.
/// Mirrors upstream `ui/haptics/Haptic` so the UI worker can call the same names.
enum Haptic {
    case tick, tap, select
    case toggleOn, toggleOff
    case skipNext, skipPrevious
    case resume, pause, expand
}

/// Tiny helper over `UIImpactFeedbackGenerator` / `NSHapticFeedbackManager`.
/// Respects Reduce Motion and a process-wide enabled flag.
enum Haptics {
    /// Set to false to mute every call without tearing the UI wiring out.
    static var isEnabled = true

    static func play(_ haptic: Haptic) {
        guard isEnabled, !reduceMotion else { return }
#if os(iOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        let intensity: CGFloat
        switch haptic {
        case .tick:
            style = .light; intensity = 0.35
        case .tap:
            style = .medium; intensity = 0.5
        case .select, .toggleOn, .resume, .expand:
            style = .medium; intensity = 0.75
        case .toggleOff, .pause:
            style = .medium; intensity = 0.55
        case .skipNext, .skipPrevious:
            style = .rigid; intensity = 0.7
        }
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred(intensity: intensity)
#elseif os(macOS)
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch haptic {
        case .tick, .tap:
            pattern = .alignment
        case .select, .toggleOn, .toggleOff, .resume, .pause, .expand:
            pattern = .generic
        case .skipNext, .skipPrevious:
            pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
#endif
    }

    private static var reduceMotion: Bool {
#if os(iOS)
        UIAccessibility.isReduceMotionEnabled
#else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#endif
    }
}

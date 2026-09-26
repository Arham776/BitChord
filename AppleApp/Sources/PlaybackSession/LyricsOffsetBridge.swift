import Foundation
import BitChordShared

/// The listener's lyrics timing correction, as the player sees it.
///
/// Thin on purpose: the range, the snapping and the label all live in shared
/// Kotlin ([LyricsOffset]) and are tested there. This only persists the number
/// and puts it where the display needs it — two callers that could otherwise
/// each hold their own idea of the range.
///
/// `Int32` throughout, because that is what crosses the boundary: Kotlin's `Int`
/// is 32-bit on every Apple target, so the conversion is exact rather than
/// lossy, and using one type end to end avoids a pair of silent casts.
enum LyricsOffsetBridge {
    private static let key = "lyrics_offset_ms"

    /// Asked of the shared side rather than restated here, so the sheet's
    /// stepper buttons cannot end up with a different step or a different range
    /// from the one that clamps the stored value. They are functions rather than
    /// constants because Kotlin/Native does not export an object's `const val`
    /// as a class property.
    static var stepMs: Int32 { LyricsOffset.shared.stepMs() }
    static var minMs: Int32 { LyricsOffset.shared.minMs() }
    static var maxMs: Int32 { LyricsOffset.shared.maxMs() }

    static func offsetMs() -> Int32 {
        LyricsOffset.shared.coerce(
            value: PlatformSettings.shared.getInt(
                key: key, default: LyricsOffset.shared.defaultMs()
            )
        )
    }

    /// Writes the value and tells the player, so the lyrics on screen move now
    /// rather than on the next track.
    private static func write(_ value: Int32) {
        let clamped = LyricsOffset.shared.coerce(value: value)
        PlatformSettings.shared.putInt(key: key, value: clamped)
        NotificationCenter.default.post(name: .lyricsOffsetChanged, object: nil)
    }

    static func set(fraction: Float) {
        write(LyricsOffset.shared.value(fraction: fraction))
    }

    static func increase() {
        write(LyricsOffset.shared.increase(value: offsetMs()))
    }

    static func decrease() {
        write(LyricsOffset.shared.decrease(value: offsetMs()))
    }

    static func reset() {
        write(LyricsOffset.shared.defaultMs())
    }

    static func format(_ value: Int32) -> String {
        LyricsOffset.shared.format(value: value)
    }

    static func fraction(_ value: Int32) -> Float {
        LyricsOffset.shared.fraction(value: value)
    }
}

extension Notification.Name {
    /// The offset changed while a track is playing. The lyrics view observes it
    /// rather than polling, so the change is visible immediately — a control
    /// that only took effect on the next track would be unusable for adjusting
    /// against the track you are listening to.
    static let lyricsOffsetChanged = Notification.Name("bitchord.lyricsOffsetChanged")
}

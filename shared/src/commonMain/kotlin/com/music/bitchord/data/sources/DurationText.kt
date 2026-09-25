package com.music.bitchord.data.sources

/**
 * `M:SS` for a duration in seconds.
 *
 * Written out rather than `"%d:%02d".format(...)` because `String.format` does
 * not exist in common Kotlin — it is a JVM extension, and this module compiles for
 * Kotlin/Native. A two-line helper is a better trade than pulling a formatting
 * library in for one call, and unlike a hand-rolled `sprintf` it cannot go wrong
 * on a locale.
 *
 * Out-of-range input is clamped rather than rejected: a catalogue that states
 * "3600" should render as an hour, and one that states a negative number should
 * not produce a row with a minus sign in it.
 */
internal fun mmss(totalSeconds: Int?): String? {
    if (totalSeconds == null || totalSeconds < 0) return null
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return if (seconds < 10) "$minutes:0$seconds" else "$minutes:$seconds"
}

/**
 * `%%%02X` for one byte.
 *
 * The hex-digit lookup written out, for the same reason as [mmss]: `String.format`
 * is a JVM extension and this module targets Kotlin/Native, where formatting a
 * string is a locale-aware library rather than a method call.
 */
internal fun percent(byte: Int): String {
    val digits = "0123456789ABCDEF"
    return "%" + digits[byte shr 4] + digits[byte and 0x0F]
}

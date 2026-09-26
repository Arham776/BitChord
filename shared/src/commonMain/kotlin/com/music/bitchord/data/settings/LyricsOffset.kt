package com.music.bitchord.data.settings

import kotlin.math.roundToInt

/**
 * The listener's own correction to synced lyrics, in milliseconds.
 *
 * ## Why this is not a per-track setting
 *
 * It is a property of the listener and the copy they are hearing, not of a
 * song: the same 200 ms of lag applies to every track on a given pair of
 * devices, and a per-track store would be something to set, forget and clear. A
 * single value in the ordinary settings, applied on the way to the display.
 *
 * Positive values delay the lyrics, negative ones bring them forward — which is
 * upstream's convention, and the one the sign has to match: the sheet's
 * description says positive shows lyrics later, and a store that reversed it
 * would be *nearly* right and wrong exactly when it mattered.
 *
 * ## Why it is clamped here rather than at the call site
 *
 * A value read from settings could have been written by an older build, a
 * hand-edited store, or a different platform's export. [coerce] runs on the way
 * in and on the way out, so there is exactly one definition of the range and no
 * caller can forget it.
 */
object LyricsOffset {

    /** ±5 seconds. Beyond that the lyrics are a different song, not a late one. */
    const val MIN_MS: Int = -5_000
    const val MAX_MS: Int = 5_000

    /**
     * 100 ms — upstream's `StepMs`.
     *
     * Coarse enough to be a usable button and fine enough to be worth having:
     * word-synced lyrics at 100 ms granularity is inside the error of the
     * timings themselves, so anything finer is pretending to a precision nobody
     * can hear.
     */
    const val STEP_MS: Int = 100

    /** The value used when nothing has been chosen, which is also "no change". */
    const val DEFAULT_MS: Int = 0

    // Exposed as functions rather than read as constants from Swift, because
    // Kotlin/Native does not export an `object`'s `const val` as a class
    // property. Without these the sheet's stepper buttons would have to carry
    // their own copy of the step and the range, and the two would drift.

    fun minMs(): Int = MIN_MS

    fun maxMs(): Int = MAX_MS

    fun stepMs(): Int = STEP_MS

    fun defaultMs(): Int = DEFAULT_MS

    /** Clamps a stored or supplied value into the range, whatever it was. */
    fun coerce(value: Int): Int = value.coerceIn(MIN_MS, MAX_MS)

    /**
     * A slider or stepper position, `0` at [MIN_MS] and `1` at [MAX_MS].
     *
     * Inverted deliberately — a slider's value grows to the right, and the
     * offset grows *up* from zero — so the mapping is the subtraction rather
     * than the addition that would look natural.
     */
    fun fraction(value: Int): Float =
        (coerce(value) - MIN_MS).toFloat() / (MAX_MS - MIN_MS)

    /**
     * The value a fraction maps back to, snapped to [STEP_MS].
     *
     * Snapping on the way in is what stops a dragged slider from storing a
     * value the stepper buttons cannot reproduce: a stored 137 ms would be
     * unreachable by pressing −/+ and the two controls would disagree about
     * where the value is. Rounding to the nearest step rather than down, so the
     * result is the closest one the buttons can actually reach.
     */
    fun value(fraction: Float): Int {
        val raw = (MIN_MS + fraction.coerceIn(0f, 1f) * (MAX_MS - MIN_MS)).toInt()
        val snapped = (raw.toFloat() / STEP_MS).roundToInt() * STEP_MS
        return coerce(snapped)
    }

    /** One step down: earlier lyrics. */
    fun decrease(value: Int): Int = coerce(value - STEP_MS)

    /** One step up: later lyrics. */
    fun increase(value: Int): Int = coerce(value + STEP_MS)

    /**
     * The offset as a signed number of milliseconds, as the display wants it.
     *
     * `+0.4s` / `−0.4s`, with a Unicode minus so the two sides of the value line
     * up — and with an explicit plus on the positive side, because an unsigned
     * `0.4s` next to a signed `−0.4s` reads as a smaller amount when it is the
     * same one.
     */
    fun format(value: Int): String {
        val ms = coerce(value)
        if (ms == 0) return "0.0s"
        val sign = if (ms > 0) "+" else "−"
        // Tenths of a second, in integers.
        //
        // Not `String.format` and not floating point: the value is a whole number
        // of milliseconds and the label has exactly one decimal place, so this is
        // exact arithmetic — no rounding, no `%.1f`, and nothing that only exists
        // on one platform. `400` ms is 4 tenths, which is "0.4s"; `5000` is 50
        // tenths, which is "5.0s" rather than the "5s" a trailing-zero-stripping
        // formatter would give and which would not line up beside it.
        val tenths = (if (ms < 0) -ms else ms) / 100
        return "$sign${tenths / 10}.${tenths % 10}s"
    }
}

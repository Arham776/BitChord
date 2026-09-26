package com.music.bitchord.data.settings

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The listener's lyrics timing correction.
 *
 * The judgement worth pinning down is the round trip through the slider: a
 * dragged control stores a value, and the ±100 ms buttons have to be able to
 * reach exactly the same values. If they cannot, the two controls disagree
 * about where the value is, which is the kind of thing that only shows up after
 * someone has already moved the slider.
 */
class LyricsOffsetTest {

    // ---- the range ---------------------------------------------------------

    @Test
    fun no_correction_is_zero() {
        assertEquals(0, LyricsOffset.coerce(0))
    }

    @Test
    fun the_range_is_plus_or_minus_five_seconds() {
        assertEquals(5_000, LyricsOffset.coerce(5_000))
        assertEquals(-5_000, LyricsOffset.coerce(-5_000))
    }

    @Test
    fun a_stored_value_beyond_the_range_is_clamped() {
        // A store can have been written by an older build, a hand edit, or a
        // different platform's export. The clamp runs on the way in so none of
        // those can put a value on screen that the stepper cannot reach.
        assertEquals(5_000, LyricsOffset.coerce(9_000))
        assertEquals(-5_000, LyricsOffset.coerce(-9_000))
    }

    @Test
    fun a_value_at_the_edge_stays_at_the_edge() {
        assertEquals(5_000, LyricsOffset.increase(5_000))
        assertEquals(-5_000, LyricsOffset.decrease(-5_000))
    }

    // ---- stepping ----------------------------------------------------------

    @Test
    fun a_step_is_a_hundred_milliseconds() {
        assertEquals(100, LyricsOffset.increase(0))
        assertEquals(-100, LyricsOffset.decrease(0))
    }

    @Test
    fun stepping_is_cumulative() {
        var value = 0
        repeat(10) { value = LyricsOffset.increase(value) }
        assertEquals(1_000, value)
        repeat(10) { value = LyricsOffset.decrease(value) }
        assertEquals(0, value)
    }

    @Test
    fun increasing_delays_the_lyrics() {
        // The sign is the whole convention. Positive shows lyrics *later*, and a
        // store that reversed it would be nearly right and wrong exactly when it
        // mattered.
        assertTrue(LyricsOffset.increase(0) > 0)
        assertTrue(LyricsOffset.decrease(0) < 0)
    }

    // ---- the slider --------------------------------------------------------

    @Test
    fun the_slider_spans_the_whole_range() {
        assertEquals(0f, LyricsOffset.fraction(LyricsOffset.MIN_MS))
        assertEquals(1f, LyricsOffset.fraction(LyricsOffset.MAX_MS))
    }

    @Test
    fun the_middle_of_the_slider_is_zero() {
        // The value someone wants first is "no correction", so it belongs in the
        // middle of the travel rather than at either end.
        assertEquals(0, LyricsOffset.value(0.5f))
    }

    @Test
    fun a_dragged_slider_lands_on_a_value_the_buttons_can_reach() {
        // The round trip that matters: anything the slider can store must be
        // reachable by pressing − or +, or the two controls disagree about where
        // the value is.
        for (step in 0..100) {
            val fraction = step / 100f
            val stored = LyricsOffset.value(fraction)
            assertEquals(
                stored,
                LyricsOffset.coerce(stored),
                "fraction $fraction stored an out-of-range value",
            )
            assertEquals(
                0,
                stored % LyricsOffset.STEP_MS,
                "fraction $fraction stored $stored, which is not a whole number of steps",
            )
        }
    }

    @Test
    fun the_slider_snaps_to_the_nearest_step_rather_than_truncating() {
        // Truncating would bias the whole slider towards early lyrics: every
        // position between two steps would report the lower one.
        assertEquals(100, LyricsOffset.value(0.51f))
        assertEquals(200, LyricsOffset.value(0.52f))
    }

    @Test
    fun a_dragged_value_comes_back_to_where_it_was_dragged() {
        for (ms in -5_000..5_000 step 100) {
            val roundTripped = LyricsOffset.value(LyricsOffset.fraction(ms))
            assertEquals(ms, roundTripped, "$ms did not survive the round trip")
        }
    }

    @Test
    fun a_fraction_outside_the_slider_is_clamped() {
        // A drag can overshoot on a trackpad, and a value of 1.2 is not a
        // position the range has.
        assertEquals(5_000, LyricsOffset.value(1.2f))
        assertEquals(-5_000, LyricsOffset.value(-0.4f))
    }

    // ---- the label ---------------------------------------------------------

    @Test
    fun no_correction_reads_as_a_bare_zero() {
        assertEquals("0.0s", LyricsOffset.format(0))
    }

    @Test
    fun a_correction_carries_its_sign() {
        assertEquals("+0.4s", LyricsOffset.format(400))
        assertEquals("−0.4s", LyricsOffset.format(-400))
    }

    @Test
    fun the_positive_side_is_signed_too() {
        // An unsigned `0.4s` beside a signed `−0.4s` reads as the smaller amount
        // when the two are the same size.
        assertTrue(LyricsOffset.format(400).startsWith("+"))
    }

    @Test
    fun the_label_uses_a_real_minus_sign() {
        // A hyphen is a different glyph from a minus and lines up wrong next to
        // digits, which is the whole point of showing the value in a column.
        assertTrue(LyricsOffset.format(-400).contains("−"))
        assertTrue(!LyricsOffset.format(-400).contains("-"))
    }

    @Test
    fun the_label_shows_a_tenth_of_a_second() {
        assertEquals("+5.0s", LyricsOffset.format(5_000))
        assertEquals("−0.1s", LyricsOffset.format(-100))
    }

    @Test
    fun the_label_clamps_a_value_from_a_hand_edited_store() {
        assertEquals("+5.0s", LyricsOffset.format(99_000))
        assertEquals("−5.0s", LyricsOffset.format(-99_000))
    }
}

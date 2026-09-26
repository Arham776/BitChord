package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Which LyricsPlus mirrors get tried, and which are skipped for now.
 *
 * The judgement worth pinning down is the distinction at the centre of it: a
 * mirror that could not be reached is a different fact from a mirror that
 * answered and had nothing. Getting that wrong in one direction writes off a
 * working mirror; in the other it retries a broken one forever.
 */
class MirrorHealthTest {

    private val mirrors = listOf("a", "b", "c")

    /** A clock the test moves by hand, so no backoff is waited on for real. */
    private class Clock(var at: Long = 1_000L) {
        fun advance(ms: Long) { at += ms }
        fun read() = at
    }

    private fun health(clock: Clock) = MirrorHealth(now = { clock.read() })

    // ---- ordering -----------------------------------------------------------

    @Test
    fun every_mirror_is_tried_when_none_has_been_used() {
        val clock = Clock()
        assertEquals(mirrors, health(clock).order(mirrors))
    }

    @Test
    fun the_last_host_to_answer_is_tried_first() {
        // The one mirror that is known to work goes first, so a track usually
        // costs one request instead of six raced ones.
        val clock = Clock()
        val h = health(clock)
        h.answered("b")
        assertEquals("b", h.order(mirrors).first())
        assertEquals(mirrors.size, h.order(mirrors).size)
    }

    @Test
    fun ordering_keeps_every_mirror_exactly_once() {
        val clock = Clock()
        val h = health(clock)
        h.answered("c")
        val order = h.order(mirrors)
        assertEquals(mirrors.size, order.size)
        assertEquals(mirrors.toSet(), order.toSet())
    }

    @Test
    fun a_host_that_answered_stays_in_the_list_after_a_later_empty_answer() {
        // "This track is not in this catalogue" says nothing about whether the
        // host works, so it must not cost the host its place at the front.
        val clock = Clock()
        val h = health(clock)
        h.answered("b")
        h.empty("b")
        assertEquals("b", h.order(mirrors).first())
        assertEquals("b", h.lastGood)
    }

    // ---- skipping -----------------------------------------------------------

    @Test
    fun an_unreachable_host_is_skipped_after_one_failure() {
        val clock = Clock()
        val h = health(clock)
        h.unreachable("b")
        assertTrue("b" !in h.order(mirrors), h.order(mirrors).toString())
    }

    @Test
    fun a_skipped_host_comes_back_when_its_penalty_expires() {
        // These are volunteer mirrors on free hosting. A certificate gets fixed
        // and a deployment gets rolled back, so a write-off would silently cost
        // the source a mirror it needed.
        val clock = Clock()
        val h = health(clock)
        h.unreachable("b")
        clock.advance(29_000)
        assertTrue("b" !in h.order(mirrors))
        clock.advance(2_000)
        assertTrue("b" in h.order(mirrors), h.order(mirrors).toString())
    }

    @Test
    fun repeated_failures_back_off_further() {
        val clock = Clock()
        val h = health(clock)
        h.unreachable("b")
        clock.advance(31_000)
        assertTrue("b" in h.order(mirrors), "the first penalty has expired, so it is retried")
        h.unreachable("b")
        clock.advance(31_000)
        assertTrue("b" !in h.order(mirrors), "the second penalty is twice as long")
    }

    @Test
    fun the_backoff_is_capped() {
        val clock = Clock()
        val h = health(clock)
        repeat(10) {
            h.unreachable("b")
            clock.advance(1_000_000)
        }
        // Capped at fifteen minutes: long enough to stop the noise, short enough
        // that a mirror that comes back is used the same afternoon.
        clock.at = 0
        h.unreachable("b")
        clock.advance(15 * 60_000L)
        assertTrue("b" in h.order(mirrors), h.order(mirrors).toString())
    }

    @Test
    fun a_host_that_answers_again_is_fully_reinstated() {
        val clock = Clock()
        val h = health(clock)
        h.unreachable("b")
        h.unreachable("b")
        clock.advance(10 * 60_000L)
        h.answered("b")
        clock.advance(10 * 60_000L)
        assertEquals("b", h.order(mirrors).first())
        assertNull(h.lastGood.takeIf { it != "b" })
    }

    @Test
    fun a_host_that_just_failed_is_not_offered_first() {
        // Whatever it was last time: it has just failed, so it is the worst
        // candidate for the request that is about to be made.
        val clock = Clock()
        val h = health(clock)
        h.answered("b")
        h.unreachable("b")
        assertTrue(h.order(mirrors).first() != "b", h.order(mirrors).toString())
    }

    // ---- the list can never go empty ---------------------------------------

    @Test
    fun every_host_failing_still_offers_someone_to_try() {
        // A health table that talked itself into an empty list would report "no
        // lyrics" for a track LyricsPlus has, and the caller could not tell that
        // from a catalogue miss.
        val clock = Clock()
        val h = health(clock)
        mirrors.forEach { h.unreachable(it) }
        assertEquals(mirrors, h.order(mirrors))
    }

    @Test
    fun a_mirror_the_table_has_never_seen_is_always_offered() {
        // A host that has never been asked cannot have been written off.
        val clock = Clock()
        val h = health(clock)
        h.unreachable("a")
        assertTrue("b" in h.order(mirrors))
        assertTrue("c" in h.order(mirrors))
    }

    @Test
    fun a_mirror_dropped_from_the_list_is_forgotten() {
        // The mirror list is a constant today, but the health table outliving a
        // host that is no longer offered would keep a stale penalty on it — and
        // a stale penalty on a host that no longer exists is a leak that never
        // gets cleaned up.
        val clock = Clock()
        val h = health(clock)
        h.unreachable("a")
        h.unreachable("b")
        assertEquals(2, h.skippedCount)
        assertEquals(listOf("a", "b"), h.order(listOf("a", "b")))
        // "a" is no longer offered, so it is dropped from the table — and only
        // "b" is ever returned, because a host that is not in the list is not a
        // host the caller can ask.
        assertEquals(listOf("b"), h.order(listOf("b")))
        assertEquals(1, h.skippedCount, h.order(listOf("b")).toString())
    }

    @Test
    fun reset_clears_both_the_penalties_and_the_last_good_host() {
        val clock = Clock()
        val h = health(clock)
        h.answered("b")
        h.unreachable("a")
        h.reset()
        assertEquals(mirrors, h.order(mirrors))
        assertNull(h.lastGood)
    }
}

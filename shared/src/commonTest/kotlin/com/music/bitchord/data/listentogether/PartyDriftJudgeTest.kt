package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * When to move the playhead.
 *
 * The judge exists to make the steady state *quiet* and the wrong state *loud*, and
 * almost every test below is about the quiet half — the cases where the gap is
 * measurable and the right answer is still to do nothing. A judge that seeks whenever
 * it can measure a difference is technically correct on every sample and unusable
 * in a room.
 */
class PartyDriftJudgeTest {

    private val judge = PartyDriftJudge()

    /** Two ticks, which is the number a real gap takes to be acted on. */
    private fun twoTicks(
        party: Long,
        local: Long,
        now: Long = 0,
        partyIsPlaying: Boolean = true,
        localIsPlaying: Boolean = true,
    ): PartyDriftJudge.Decision {
        judge.onTick(party, local, localIsPlaying, partyIsPlaying, now)
        return judge.onTick(party, local, localIsPlaying, partyIsPlaying, now + PARTY_TICK_MS)
    }

    // ---- The quiet half ----------------------------------------------------

    @Test
    fun `a device in step is left alone`() {
        assertEquals(PartyDriftJudge.Decision.None, twoTicks(party = 30_000, local = 30_000))
    }

    @Test
    fun `a gap too small to hear is left alone`() {
        // Below the alignment tolerance a correction costs more than the error. 120 ms
        // is under the threshold of noticing on music, so this is not a masking
        // argument: the error genuinely is not there.
        assertEquals(PartyDriftJudge.Decision.None, twoTicks(party = 30_000, local = 30_100))
    }

    @Test
    fun `a gap over the tolerance but under the limit is still left alone`() {
        // 600 ms is measurable and still not worth a discontinuity.
        assertEquals(PartyDriftJudge.Decision.None, twoTicks(party = 30_000, local = 30_600))
    }

    @Test
    fun `one wide tick is not acted on`() {
        // Usually one slow frame, and correcting on it means correcting on network
        // noise — which is how a party ends up seeking on every hiccup.
        assertEquals(
            PartyDriftJudge.Decision.None,
            judge.onTick(partyPositionMs = 30_000, localPositionMs = 20_000, localIsPlaying = true, partyIsPlaying = true, nowMs = 0),
        )
    }

    @Test
    fun `a gap that clears is forgiven`() {
        // So a real gap cannot be banked by a momentary blur cancelling a strike.
        judge.onTick(30_000, 20_000, true, true, 0)
        judge.onTick(30_000, 30_000, true, true, PARTY_TICK_MS) // clear
        assertEquals(
            PartyDriftJudge.Decision.None,
            judge.onTick(30_000, 20_000, true, true, PARTY_TICK_MS * 2),
        )
    }

    // ---- The loud half -----------------------------------------------------

    @Test
    fun `two consecutive wide ticks seek`() {
        val decision = twoTicks(party = 30_000, local = 20_000)
        val seek = assertIs<PartyDriftJudge.Decision.Seek>(decision)
        assertEquals(30_000, seek.seekToMs)
    }

    @Test
    fun `a persistent gap is not machine-gunned`() {
        // Without the cooldown the two-strike rule does not compound: the gap stays
        // over the limit, so every pair of ticks would seek.
        val seekTimes = mutableListOf<Long>()
        var now = 0L
        repeat(10) {
            judge.onTick(30_000, 20_000, true, true, now)
            val decision = judge.onTick(30_000, 20_000, true, true, now + PARTY_TICK_MS)
            if (decision is PartyDriftJudge.Decision.Seek) seekTimes += now + PARTY_TICK_MS
            now += PARTY_TICK_MS
        }
        // Ten ticks at 700 ms is seven seconds, so the space between the first seek
        // and the second is asserted rather than a count — a count would also pass if
        // the rule fired twice inside one window and not at all in the next.
        assertEquals(2, seekTimes.size, "seeks at $seekTimes")
        // Ticks are 700 ms apart, so the earliest the second can be is the first tick
        // at or after the cooldown — 6300 ms here rather than 6000 exactly.
        assertTrue(
            seekTimes[1] - seekTimes[0] >= PartyDriftJudge.DRIFT_COOLDOWN_MS,
            "seeks were $seekTimes",
        )
    }

    @Test
    fun `a seek is available again after the cooldown`() {
        twoTicks(party = 30_000, local = 20_000, now = 0) // the one seek
        // Well past the cooldown, and two more wide ticks.
        val later = PartyDriftJudge.DRIFT_COOLDOWN_MS + 10_000
        judge.onTick(30_000, 20_000, true, true, later)
        val decision = judge.onTick(30_000, 20_000, true, true, later + PARTY_TICK_MS)
        assertIs<PartyDriftJudge.Decision.Seek>(decision)
    }

    @Test
    fun `a suppressed seek does not bank a strike`() {
        // Two ticks inside the cooldown, then two just after it: the third and fourth
        // are the ones that act, which is only true if the suppressed pair left
        // nothing behind.
        twoTicks(party = 30_000, local = 20_000, now = 0) // seeks
        twoTicks(party = 30_000, local = 20_000, now = 1_000) // suppressed
        val after = PartyDriftJudge.DRIFT_COOLDOWN_MS + 1_000
        judge.onTick(30_000, 20_000, true, true, after)
        assertIs<PartyDriftJudge.Decision.Seek>(judge.onTick(30_000, 20_000, true, true, after + PARTY_TICK_MS))
    }

    @Test
    fun `a device ahead of the party is pulled back`() {
        // Asymmetric in the same way: the judge follows the party whichever side it
        // is on, because the party is the thing everyone else is listening to.
        val seek = assertIs<PartyDriftJudge.Decision.Seek>(twoTicks(party = 30_000, local = 40_000))
        assertEquals(30_000, seek.seekToMs)
    }

    @Test
    fun `a corrected position is never negative`() {
        // A negative seek is a fault, not an alignment.
        val seek = assertIs<PartyDriftJudge.Decision.Seek>(twoTicks(party = -5_000, local = 20_000))
        assertEquals(0, seek.seekToMs)
    }

    // ---- A paused party ----------------------------------------------------

    @Test
    fun `a playing device stops when the party pauses`() {
        val decision = judge.onTick(
            partyPositionMs = 30_000, localPositionMs = 30_000, localIsPlaying = true, partyIsPlaying = false, nowMs = 0,
        )
        assertEquals(PartyDriftJudge.Decision.Pause, decision)
    }

    @Test
    fun `a playing device stops even at exactly the same position`() {
        // The bug this replaced compared positions and reported "close enough" when
        // the gap was zero — so a device playing at the paused party's own position
        // was left playing, and the listener heard music nobody chose. Being out of
        // step is measured in milliseconds; playing when the party is paused is a
        // different kind of wrong, and no tolerance covers it.
        val decision = judge.onTick(
            partyPositionMs = 30_000, localPositionMs = 30_000, localIsPlaying = true, partyIsPlaying = false, nowMs = 0,
        )
        assertEquals(PartyDriftJudge.Decision.Pause, decision)
    }

    @Test
    fun `a pause needs no strikes and no cooldown`() {
        // Pausing is not audible the way seeking is, so the whole two-strike and
        // cooldown machinery does not apply to it — it is answered on the first tick.
        val judge = PartyDriftJudge()
        repeat(3) { index ->
            val decision = judge.onTick(30_000, 20_000, true, false, index * PARTY_TICK_MS)
            assertEquals(PartyDriftJudge.Decision.Pause, decision)
        }
    }

    @Test
    fun `a paused party clears the strike count`() {
        // Otherwise a gap that was building when the party paused is still half-built
        // when it resumes, and the first tick after a resume seeks.
        judge.onTick(30_000, 20_000, true, true, 0) // strike one
        judge.onTick(30_000, 20_000, true, false, PARTY_TICK_MS) // paused: cleared
        // This is the tick that proves the clearing. Had the pre-pause strike survived,
        // this would be the second one and would seek.
        assertEquals(
            PartyDriftJudge.Decision.None,
            judge.onTick(30_000, 20_000, true, true, PARTY_TICK_MS * 2),
            "the count was not cleared, so this acted on a banked strike",
        )
        assertIs<PartyDriftJudge.Decision.Seek>(
            judge.onTick(30_000, 20_000, true, true, PARTY_TICK_MS * 3),
            "and a fresh pair should then act",
        )
    }

    // ---- Following, and resetting ------------------------------------------

    @Test
    fun `following is judged on the same tolerance as alignment`() {
        // One number for both, so the indicator on screen and the behaviour of the
        // player cannot disagree.
        assertTrue(isFollowing(30_000, 30_000))
        assertTrue(isFollowing(30_000, 30_100))
        assertTrue(!isFollowing(30_000, 32_000))
    }

    @Test
    fun `resetting clears the strike count and the cooldown`() {
        twoTicks(party = 30_000, local = 20_000, now = 0) // seeks
        judge.reset()
        // Would be suppressed by the cooldown if the reset had not cleared it.
        assertIs<PartyDriftJudge.Decision.Seek>(twoTicks(party = 30_000, local = 20_000, now = 1_000))
    }
}

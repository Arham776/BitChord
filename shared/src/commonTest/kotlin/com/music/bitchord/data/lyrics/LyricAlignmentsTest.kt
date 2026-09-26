package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Which side of the lyrics panel each line is sung from.
 *
 * Two things are being pinned down and both are invisible when they go wrong: a
 * duet laid out entirely on one side still *reads*, and a three-way song with two
 * voices stacked on the same side still reads — it just stops being a
 * conversation. So the rule is checked against the shapes it is meant to
 * produce rather than against "looks right".
 */
class LyricAlignmentsTest {

    private fun sides(vararg singers: String?, types: Map<String, String> = emptyMap()) =
        lineAlignments(singers.toList(), types)

    // ---- a single voice -----------------------------------------------------

    @Test
    fun one_voice_is_all_on_one_side() {
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.Start, LyricAlignment.Start),
            sides("v1", "v1", "v1"),
        )
    }

    @Test
    fun a_line_with_no_agent_is_on_the_left() {
        // Most providers name no agent at all, and every one of their lines has to
        // land on the left rather than being treated as a voice of its own.
        assertEquals(listOf(LyricAlignment.Start), sides(null))
        assertEquals(listOf(LyricAlignment.Start, LyricAlignment.Start), sides("", "v1"))
    }

    // ---- two voices ---------------------------------------------------------

    @Test
    fun two_voices_alternate_sides() {
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End, LyricAlignment.Start),
            sides("v1", "v2", "v1"),
        )
    }

    @Test
    fun consecutive_lines_by_one_voice_stay_on_their_side() {
        // The alternation is on the voice *changing*, not on the line number.
        assertEquals(
            listOf(
                LyricAlignment.Start, LyricAlignment.Start,
                LyricAlignment.End, LyricAlignment.End,
            ),
            sides("v1", "v1", "v2", "v2"),
        )
    }

    @Test
    fun three_voices_keep_taking_turns() {
        // One side per voice would put two of the three on top of each other and
        // the song would stop reading as a conversation.
        assertEquals(
            listOf(
                LyricAlignment.Start, LyricAlignment.End, LyricAlignment.Start,
                LyricAlignment.End, LyricAlignment.Start,
            ),
            sides("v1", "v2", "v3", "v1", "v2"),
        )
    }

    // ---- the reserved agents ------------------------------------------------

    @Test
    fun the_group_voice_stays_on_the_left_without_taking_a_turn() {
        // Everyone at once belongs to neither side, and must not disturb whose
        // turn it is — otherwise a chorus would shift the whole duet.
        assertEquals(
            listOf(
                LyricAlignment.Start, LyricAlignment.Start, LyricAlignment.End,
            ),
            sides("v1", "v1000", "v2"),
        )
    }

    @Test
    fun the_reserved_other_voice_starts_on_the_right() {
        // `v2000` is the other singer, and the walk starts by giving the left to
        // whoever is not it.
        assertEquals(
            listOf(LyricAlignment.End, LyricAlignment.Start),
            sides("v2000", "v1"),
        )
    }

    @Test
    fun a_declared_type_beats_the_reserved_id() {
        // Where the head declares the type, that is the truth: an agent called
        // `v2000` declared as a group is a group.
        assertEquals(
            listOf(LyricAlignment.Start),
            sides("v2000", types = mapOf("v2000" to "group")),
        )
    }

    @Test
    fun a_declared_person_beats_the_default() {
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End),
            sides("a", "b", types = mapOf("a" to "person", "b" to "person")),
        )
    }

    // ---- the flip -----------------------------------------------------------

    @Test
    fun a_song_that_opens_on_the_second_voice_is_flipped_back() {
        // The walk starts on the left, so this comes out entirely on the right —
        // correct by the rule and plainly not what was meant.
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End, LyricAlignment.Start),
            sides("v2", "v1", "v2"),
        )
    }

    @Test
    fun a_genuine_duet_is_not_flipped() {
        // Evenly split, so the flip does not fire.
        val duet = List(20) { if (it % 2 == 0) "v1" else "v2" }
        val out = sides(*duet.toTypedArray())
        assertEquals(10, out.count { it == LyricAlignment.End })
    }

    @Test
    fun a_duet_with_a_group_chorus_is_not_flipped() {
        // A chorus or two sung by the group is ordinary, and must not be enough to
        // call the whole song a duet that happens to lean right. Ten alternating
        // lines are five each way, and the group lines are all on the left, so a
        // half of the placed lines are on the right — nowhere near the 85% that
        // would trigger the flip.
        val singers = buildList {
            repeat(10) { add(if (it % 2 == 0) "v1" else "v2") }
            repeat(4) { add("v1000") }
        }
        val out = sides(*singers.toTypedArray())
        assertEquals(5, out.count { it == LyricAlignment.End })
    }

    @Test
    fun a_duet_that_leans_heavily_right_is_still_flipped() {
        // The control for the chorus case: the same shape without the group lines,
        // but with a long answering passage, so the share of right-hand lines does
        // pass the threshold and the flip is the right answer.
        val singers = buildList {
            add("v2")
            repeat(20) { add("v1") }
        }
        val out = sides(*singers.toTypedArray())
        assertEquals(20, out.count { it == LyricAlignment.Start })
    }

    // ---- the degenerate cases ----------------------------------------------

    @Test
    fun an_empty_track_places_nothing() {
        assertEquals(emptyList(), sides())
    }

    @Test
    fun a_track_with_no_agents_at_all_is_left_alone() {
        // Nothing placed means there is no share to flip, and flipping anyway
        // would turn a whole plain transcript to the right.
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.Start),
            sides(null, null),
        )
    }

    @Test
    fun the_number_of_sides_always_matches_the_number_of_lines() {
        // The caller pairs these up by index, so a short answer would shift every
        // later line's side rather than just losing the last one.
        for (count in 0..8) {
            val singers = List(count) { if (it % 2 == 0) "v1" else "v2" }
            assertEquals(count, sides(*singers.toTypedArray()).size)
        }
    }
}

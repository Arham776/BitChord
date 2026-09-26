package com.music.bitchord.data.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The stored form of [OriginalVersion]'s pin set.
 *
 * The round trip is the judgement worth pinning down: a pin the app wrote has to
 * survive being read back, and a store anything else touched must not be able to
 * invent a pin for a track that does not exist.
 */
class OriginalVersionCodecTest {

    private fun roundTrip(vararg ids: String): Set<String> =
        OriginalVersion.decode(OriginalVersion.encode(ids.toSet()))

    @Test
    fun an_empty_set_stores_as_an_empty_string() {
        assertEquals("", OriginalVersion.encode(emptySet()))
    }

    @Test
    fun an_empty_string_decodes_to_no_pins() {
        assertEquals(emptySet(), OriginalVersion.decode(""))
    }

    @Test
    fun ids_survive_a_round_trip() {
        assertEquals(
            setOf("dQw4w9WgXcQ", "oHg5SJYRHA0", "9bZkp7q19f0"),
            roundTrip("dQw4w9WgXcQ", "oHg5SJYRHA0", "9bZkp7q19f0"),
        )
    }

    @Test
    fun a_single_pin_survives_a_round_trip() {
        assertEquals(setOf("dQw4w9WgXcQ"), roundTrip("dQw4w9WgXcQ"))
    }

    @Test
    fun the_stored_form_is_ordered_so_a_diff_is_readable() {
        // Sorted because the value is a settings string a human may end up
        // looking at, and two devices that pinned the same tracks in a different
        // order should not then disagree about what they stored.
        assertEquals(
            "aaa\naaa2\nzzz",
            OriginalVersion.encode(setOf("zzz", "aaa2", "aaa")),
        )
    }

    @Test
    fun a_repeated_id_stores_once() {
        assertEquals("dQw4w9WgXcQ", OriginalVersion.encode(setOf("dQw4w9WgXcQ", "dQw4w9WgXcQ")))
    }

    @Test
    fun blank_lines_do_not_become_pins() {
        // The store is a settings string; a trailing newline is what a naive
        // writer produces, and a blank line must not pin a track named "".
        assertEquals(setOf("dQw4w9WgXcQ"), OriginalVersion.decode("\ndQw4w9WgXcQ\n\n"))
    }

    @Test
    fun whitespace_only_lines_do_not_become_pins() {
        assertEquals(emptySet(), OriginalVersion.decode("   \n\t\n \t "))
    }

    @Test
    fun surrounding_whitespace_is_trimmed_off_each_id() {
        assertEquals(setOf("dQw4w9WgXcQ"), OriginalVersion.decode("  dQw4w9WgXcQ  "))
    }

    @Test
    fun carriage_returns_from_a_windows_edited_store_are_trimmed() {
        // A store that came through a text editor on another platform carries
        // \r\n. Trimming is what stops "dQw4w9WgXcQ\r" becoming a different id
        // from "dQw4w9WgXcQ" — which would silently pin a track that does not
        // exist and leave the real one upgradable.
        assertEquals(setOf("dQw4w9WgXcQ", "oHg5SJYRHA0"), OriginalVersion.decode("dQw4w9WgXcQ\r\noHg5SJYRHA0\r\n"))
    }

    @Test
    fun a_pin_is_never_split_by_a_separator_inside_it() {
        // Why the format is newline-separated rather than comma-separated: a
        // comma inside a value would split one pin into two, and neither half
        // is a track. The decoder must not do that to a value that contains
        // one, and a real video id never does.
        val hostile = "dQw4w9WgXcQ,oHg5SJYRHA0"
        assertEquals(setOf(hostile), OriginalVersion.decode(hostile))
    }

    @Test
    fun an_id_containing_a_space_survives_trimming() {
        // Trimming is about the edges only. An interior space is not something
        // the decoder gets to editorialise on.
        assertEquals(setOf("a b"), OriginalVersion.decode("a b"))
    }
}

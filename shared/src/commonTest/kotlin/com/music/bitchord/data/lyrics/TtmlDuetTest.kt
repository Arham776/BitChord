package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A duet out of Apple Music TTML.
 *
 * Built with builders rather than pasted as a document, because the thing being
 * checked is that the *attribute* on the line is read and carried through to a
 * side — and a pasted fixture makes it far too easy to be testing the shape of
 * the XML rather than the behaviour of the parser.
 */
class TtmlDuetTest {

    /** One `<p>`, with its voice, its window and its timed words. */
    private fun line(
        begin: String,
        end: String? = null,
        agent: String? = null,
        words: List<Pair<String, String>> = listOf("words" to begin),
    ): String {
        val attrs = buildString {
            append(" begin=\"").append(begin).append('"')
            end?.let { append(" end=\"").append(it).append('"') }
            agent?.let { append(" ttm:agent=\"").append(it).append('"') }
        }
        val spans = words.mapIndexed { index, (text, at) ->
            // A word runs until the next one starts, and the last runs to the
            // line's own end — which is what a reader would expect of a document
            // that did not spell every word out.
            val until = words.getOrNull(index + 1)?.second ?: end ?: at
            "<span begin=\"$at\" end=\"$until\">$text</span>"
        }.joinToString("")
        return "<p$attrs>$spans</p>"
    }

    /**
     * A whole document. [lines] first so the calls read as the document does, and
     * [agents] last because Kotlin will not take positional varargs after a named
     * argument.
     */
    private fun document(
        vararg lines: String,
        agents: List<Pair<String, String>> = emptyList(),
    ): String {
        val head = agents.joinToString("") { (id, type) ->
            "<ttm:agent xml:id=\"$id\" type=\"$type\"/>"
        }
        return "<tt><head>$head</head><body>${lines.joinToString("")}</body></tt>"
    }

    // ---- the ordinary case --------------------------------------------------

    @Test
    fun a_line_with_no_agent_is_on_the_left() {
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", words = listOf("one" to "0.0", "two" to "1.0")),
                line(begin = "3.0", words = listOf("three" to "3.0", "four" to "4.0")),
            )
        )
        assertTrue(lines.all { it.alignment == LyricAlignment.Start })
    }

    @Test
    fun the_words_and_the_timings_survive_the_alignment_pass() {
        // The sides are decided in a second pass, and a second pass that rebuilt
        // the lines would quietly lose everything the first pass parsed.
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", agent = "v1", words = listOf("one" to "0.0", "two" to "1.0")),
                line(begin = "3.0", agent = "v2", words = listOf("three" to "3.0", "four" to "4.0")),
                agents = listOf("v1" to "person", "v2" to "person"),
            )
        )
        assertEquals(2, lines.size)
        assertEquals("one two", lines[0].text)
        assertEquals("three four", lines[1].text)
        assertEquals(2, lines[0].words.size)
        assertEquals(0L, lines[0].timeMs)
        assertEquals(3_000L, lines[1].timeMs)
    }

    // ---- a duet -------------------------------------------------------------

    @Test
    fun two_voices_come_out_on_opposite_sides() {
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", agent = "v1", words = listOf("mine" to "0.0")),
                line(begin = "3.0", agent = "v2", words = listOf("yours" to "3.0")),
                line(begin = "6.0", agent = "v1", words = listOf("mine again" to "6.0")),
                agents = listOf("v1" to "person", "v2" to "person"),
            )
        )
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End, LyricAlignment.Start),
            lines.map { it.alignment },
        )
    }

    @Test
    fun a_duet_with_a_group_chorus_keeps_the_chorus_on_the_left() {
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", agent = "v1", words = listOf("mine" to "0.0")),
                line(begin = "3.0", agent = "v2", words = listOf("yours" to "3.0")),
                line(begin = "6.0", agent = "v1000", words = listOf("together" to "6.0")),
                line(begin = "9.0", agent = "v1", words = listOf("mine" to "9.0")),
                agents = listOf("v1" to "person", "v2" to "person", "v1000" to "group"),
            )
        )
        assertEquals(
            listOf(
                LyricAlignment.Start, LyricAlignment.End,
                LyricAlignment.Start, LyricAlignment.Start,
            ),
            lines.map { it.alignment },
        )
    }

    @Test
    fun a_duet_that_opens_on_the_second_voice_is_flipped_back() {
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", agent = "v2", words = listOf("theirs" to "0.0")),
                line(begin = "3.0", agent = "v1", words = listOf("mine" to "3.0")),
                line(begin = "6.0", agent = "v2", words = listOf("theirs again" to "6.0")),
                agents = listOf("v1" to "person", "v2" to "person"),
            )
        )
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End, LyricAlignment.Start),
            lines.map { it.alignment },
        )
    }

    // ---- no declaration -----------------------------------------------------

    @Test
    fun an_undeclared_agent_is_still_treated_as_a_voice() {
        // Only the id is on the line, so where the head declares nothing the two
        // reserved ids still mean something and anything else is a person.
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", agent = "a", words = listOf("mine" to "0.0")),
                line(begin = "3.0", agent = "b", words = listOf("yours" to "3.0")),
            )
        )
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End),
            lines.map { it.alignment },
        )
    }

    @Test
    fun a_bare_agent_attribute_is_read_too() {
        // The same attribute appears without its prefix under a document that
        // declares no namespace, and it is the same attribute.
        val ttml = "<tt><body>" +
            "<p begin=\"0.0\" agent=\"a\"><span begin=\"0.0\" end=\"1.0\">mine</span></p>" +
            "<p begin=\"3.0\" agent=\"b\"><span begin=\"3.0\" end=\"4.0\">yours</span></p>" +
            "</body></tt>"
        val lines = TtmlLyrics.parse(ttml)
        assertEquals(
            listOf(LyricAlignment.Start, LyricAlignment.End),
            lines.map { it.alignment },
        )
    }

    // ---- the gaps -----------------------------------------------------------

    @Test
    fun an_instrumental_gap_is_on_the_left() {
        // Gaps belong to nobody, and giving one the side of the line it follows
        // would put an empty row in the middle of a duet.
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", end = "2.0", agent = "v1", words = listOf("mine" to "0.0")),
                line(begin = "8.0", end = "10.0", agent = "v2", words = listOf("yours" to "8.0")),
                agents = listOf("v1" to "person", "v2" to "person"),
            )
        )
        assertEquals(3, lines.size, "the gap should be a line of its own")
        assertTrue(lines[1].isGap)
        assertEquals(LyricAlignment.Start, lines[1].alignment)
    }

    @Test
    fun a_gap_does_not_disturb_whose_turn_it_is() {
        val lines = TtmlLyrics.parse(
            document(
                line(begin = "0.0", end = "2.0", agent = "v1", words = listOf("mine" to "0.0")),
                line(begin = "8.0", end = "10.0", agent = "v2", words = listOf("yours" to "8.0")),
                line(begin = "12.0", end = "14.0", agent = "v1", words = listOf("mine" to "12.0")),
                agents = listOf("v1" to "person", "v2" to "person"),
            )
        )
        assertEquals(
            listOf(
                LyricAlignment.Start, LyricAlignment.Start, LyricAlignment.End,
                LyricAlignment.Start,
            ),
            lines.map { it.alignment },
        )
    }
}

package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The shape a lyric takes when it crosses to the host and back.
 *
 * A translation is only worth having if it still lines up with the music, and
 * lining up means every timing, every gap and every background vocal survives the
 * round trip. Those are exactly the fields a convenience mapping drops, so they
 * are the ones tested here rather than the text.
 */
class LyricLineDocumentTest {

    private val document = """
        {"lines":[
          {"timeMs":1000,"text":"first","words":[
            {"startMs":1000,"endMs":1400,"text":"first"},
            {"startMs":1400,"endMs":1900,"text":"line"}],
           "sungUntilMs":1900,"background":null},
          {"timeMs":4000,"text":"","words":[],"sungUntilMs":null,"background":null},
          {"timeMs":6000,"text":"lead","words":[],"sungUntilMs":7000,
           "background":{"timeMs":6200,"text":"answering","words":[
             {"startMs":6200,"endMs":6800,"text":"answering"}],
             "sungUntilMs":null,"background":null}}
        ]}
    """.trimIndent()

    @Test
    fun `the document decodes to the lines it describes`() {
        val lines = decode(document)
        assertEquals(3, lines.size)
        assertEquals("first", lines[0].text)
    }

    @Test
    fun `word timings survive the trip`() {
        val words = decode(document)[0].words
        assertEquals(2, words.size)
        assertEquals(1000L, words[0].startMs)
        assertEquals(1900L, words[1].endMs)
        assertEquals("line", words[1].text)
    }

    @Test
    fun `a line's own end survives`() {
        // Without it an interlude cannot be told from a slowly sung line, and the
        // panel draws them differently.
        assertEquals(1900L, decode(document)[0].sungUntilMs)
    }

    @Test
    fun `a background vocal survives with its own words`() {
        val background = assertNotNull(decode(document)[2].background)
        assertEquals("answering", background.text)
        assertEquals(1, background.words.size)
        assertEquals(6200L, background.words[0].startMs)
    }

    @Test
    fun `an instrumental gap survives as a blank line`() {
        // The gap is what makes the panel breathe; a translation that dropped the
        // blank lines would look like the lyrics had been deleted.
        val gap = decode(document)[1]
        assertEquals("", gap.text)
        assertTrue(gap.isGap)
        assertEquals(4000L, gap.timeMs)
    }

    @Test
    fun `a line with no end says so rather than claiming zero`() {
        // `0` is a real time — the first thing that can happen — so absence has to
        // stay absent.
        assertNull(decode(document)[1].sungUntilMs)
    }

    @Test
    fun `a nested background does not lose its own background`() {
        val nested = """
            {"lines":[{"timeMs":0,"text":"a","words":[],"sungUntilMs":null,
              "background":{"timeMs":100,"text":"b","words":[],"sungUntilMs":null,
                "background":{"timeMs":200,"text":"c","words":[],"sungUntilMs":null,
                  "background":null}}}]}
        """.trimIndent()
        val deepest = decode(nested)[0].background?.background
        assertEquals("c", deepest?.text)
        assertEquals(200L, deepest?.timeMs)
    }

    @Test
    fun `an empty document decodes to nothing rather than throwing`() {
        assertEquals(0, decode("""{"lines":[]}""").size)
    }

    @Test
    fun `a document that is not one decodes to nothing`() {
        // A malformed answer must not take the panel down with it.
        assertEquals(0, decode("not json at all").size)
        assertEquals(0, decode("""{"unexpected":true}""").size)
        assertEquals(0, decode("").size)
    }

    @Test
    fun `a malformed document yields no lyric at all rather than a partial one`() {
        // A word with no end is a word whose glow would be drawn from nowhere, so
        // it is not defaulted to 0. The consequence is that the whole document is
        // refused rather than partially read — which is the right way round: a
        // lyric missing one line reads as a song with fewer words, and a lyric
        // missing its timings reads as words arriving at the wrong moment. The
        // panel showing nothing says the truth.
        val partial = """{"lines":[{"timeMs":0,"text":"a","words":[
            {"startMs":0,"text":"half"}],"sungUntilMs":null,"background":null}]}"""
        assertTrue(decode(partial).isEmpty())
    }

    // ---- The same shape the host writes ------------------------------------

    @Test
    fun `a host-written document reads back identically`() {
        val original = listOf(
            LyricLineDto(
                timeMs = 1000,
                text = "first",
                words = listOf(LyricWordDto(1000, 1400, "first")),
                sungUntilMs = 1900,
            ),
            LyricLineDto(
                timeMs = 6000,
                text = "lead",
                words = emptyList(),
                background = LyricLineDto(
                    timeMs = 6200,
                    text = "answering",
                    words = listOf(LyricWordDto(6200, 6800, "answering")),
                ),
            ),
        )
        val round = decode(encode(original))
        assertEquals(original.size, round.size)
        assertEquals(original[0].text, round[0].text)
        assertEquals(original[0].sungUntilMs, round[0].sungUntilMs)
        assertEquals(1, round[0].words.size)
        assertEquals("answering", round[1].background?.text)
        assertEquals(1, round[1].background?.words?.size)
    }

    @Test
    fun `an empty list round-trips to nothing`() {
        // Asserted as a round trip rather than on the encoded text: the field is
        // omitted when it is empty, and what matters is that the host reads it
        // back as no lines — not that a particular key is present.
        assertTrue(decode(encode(emptyList())).isEmpty())
    }

    // Mirrors of the bridge's own codec, so the test exercises the shape rather
    // than the bridge's plumbing.
    private fun decode(document: String): List<LyricLineDto> = runCatching {
        lyricsJson.decodeFromString(LyricLineList.serializer(), document).lines
    }.getOrDefault(emptyList())

    private fun encode(lines: List<LyricLineDto>): String = runCatching {
        lyricsJson.encodeToString(LyricLineList.serializer(), LyricLineList(lines))
    }.getOrDefault("""{"lines":[]}""")
}

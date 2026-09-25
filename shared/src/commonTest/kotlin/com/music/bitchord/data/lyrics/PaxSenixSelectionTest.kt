package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The two things the authenticated PaxSeniX routes get wrong if they are wrong:
 * choosing the wrong recording, and losing the word timings.
 */
class PaxSenixSelectionTest {

    // ---- The structured Apple payload --------------------------------------

    private val timedApple = """
        {"content":[
          {"timestamp":1000,"text":[
            {"text":"Hello","timestamp":1000},
            {"text":"world","timestamp":1400}]},
          {"timestamp":3000,"text":[
            {"text":"Goodbye","timestamp":3000},
            {"text":"now","timestamp":3600}]},
          {"timestamp":5000,"text":[
            {"text":"Final","timestamp":5000}]}
        ]}
    """.trimIndent()

    @Test
    fun `the structured payload is read with its line and word timings`() {
        val lines = PaxSenix.parseTimedApple(timedApple)
        assertEquals(3, lines?.size)
        assertEquals(1000L, lines?.first()?.timeMs)
        assertEquals("Hello world", lines?.first()?.text)
    }

    @Test
    fun `word timings survive`() {
        val words = PaxSenix.parseTimedApple(timedApple)?.first()?.words
        assertEquals(2, words?.size)
        assertEquals(1000L, words?.first()?.startMs)
        // "world" starts at 1400 and is *held* until the next thing happens at
        // 3000. A word's length is how long it is sung for, not the gap to the
        // next syllable — ending it at its own start would make every word blink.
        assertEquals(1400L, words?.last()?.startMs)
        assertEquals(3000L, words?.last()?.endMs)
    }

    @Test
    fun `a word ends where the next one begins`() {
        // The end of a word is the start of the next, or the start of the next
        // line. Inventing nothing leaves the last word of every line lit forever.
        val lines = PaxSenix.parseTimedApple(timedApple)!!
        assertEquals(3000L, lines[0].words.last().endMs)
    }

    @Test
    fun `a word with no successor gets a nominal length rather than none`() {
        val words = PaxSenix.parseTimedApple(timedApple)!!.last().words
        assertEquals(1, words.size)
        assertTrue(words[0].endMs > words[0].startMs)
    }

    @Test
    fun `a line runs to the next line's start`() {
        val lines = PaxSenix.parseTimedApple(timedApple)!!
        assertEquals(3000L, lines[0].sungUntilMs)
        // The last line has no successor, so it claims no end.
        assertNull(lines.last().sungUntilMs)
    }

    @Test
    fun `a payload nested inside an envelope is still found`() {
        val nested = """{"data":{"lyrics":{"content":$timedApple}}}"""
        assertEquals(3, PaxSenix.parseTimedApple(nested)?.size)
    }

    @Test
    fun `a payload with no timestamps is not this format`() {
        // It is a search result, not lyrics. Recognising it as timed would
        // produce a lyric with nothing in it.
        assertNull(PaxSenix.parseTimedApple("""{"content":[{"text":"a"}]}"""))
        assertNull(PaxSenix.parseTimedApple("""{"ttmlContent":"<tt/>"}"""))
    }

    @Test
    fun `a line whose words are only partly timed is treated as line-synced`() {
        // A partial word set animates some syllables and leaves the rest dead,
        // which reads as the provider being unreliable rather than as half an
        // answer. The whole line falls back to line timing instead.
        val partial = """
            {"content":[{"timestamp":1000,"text":[
              {"text":"Hello","timestamp":1000},
              {"text":"world"}]}]}
        """.trimIndent()
        val line = PaxSenix.parseTimedApple(partial)?.single()
        assertTrue(line != null)
        assertTrue(line!!.words.isEmpty())
        assertEquals("Hello world", line.text)
    }

    @Test
    fun `a line with no text is dropped`() {
        val empty = """{"content":[{"timestamp":1000,"text":[]}]}"""
        assertNull(PaxSenix.parseTimedApple(empty))
    }

    // ---- Choosing one recording out of a search ---------------------------

    private val twoRecordings = """
        {"results":[
          {"id":"wrong","attributes":{"name":"Same Title","artistName":"A Different Band",
            "durationInMillis":200000}},
          {"id":"right","attributes":{"name":"Same Title","artistName":"The Right Band",
            "durationInMillis":205000}}
        ]}
    """.trimIndent()

    @Test
    fun `the search result that names the right recording is chosen`() {
        // The whole point of the floor and the scoring: two songs with the same
        // title, and picking the wrong one plays the wrong lyrics in time with
        // the wrong song.
        val lines = PaxSenix.parseLrcGet(
            """{"lyrics":[
              {"id":"wrong","attributes":{"name":"Same Title","artistName":"A Different Band",
                "durationInMillis":200000},"lines":[{"timestamp":1,"text":"wrong"}]},
              {"id":"right","attributes":{"name":"Same Title","artistName":"The Right Band",
                "durationInMillis":205000},"lines":[{"timestamp":1,"text":"right"}]}
            ]}""",
            title = "Same Title",
            artist = "The Right Band",
            durationMs = 205_000,
        )
        assertEquals("right", lines?.single()?.text)
    }

    @Test
    fun `a search result with no candidates array is read as one document`() {
        val lines = PaxSenix.parseLrcGet(
            """{"ttmlContent":"<tt/>"}""",
            title = "Anything",
            artist = "Anyone",
            durationMs = 0,
        )
        // Unparseable, so nothing — but it must not throw on the shape.
        assertNull(lines)
    }

    @Test
    fun `an empty candidate list is a miss rather than a crash`() {
        assertNull(PaxSenix.parseLrcGet(
            """{"lyrics":[]}""", title = "A", artist = "B", durationMs = 0,
        ))
    }

    // ---- The key ----------------------------------------------------------

    @Test
    fun `a pasted authorization header is unwrapped`() {
        // A settings field somebody filled in by copying the whole header value.
        assertEquals("abc123", normalizePaxSenixApiKey("Bearer abc123"))
        assertEquals("abc123", normalizePaxSenixApiKey("bearer abc123"))
        assertEquals("abc123", normalizePaxSenixApiKey("  Bearer   abc123  "))
    }

    @Test
    fun `a bare token is taken as it stands`() {
        assertEquals("abc123", normalizePaxSenixApiKey("abc123"))
    }

    @Test
    fun `a token that happens to contain a space is not cut in half`() {
        // The prefix is stripped, rather than the token being extracted by
        // splitting — so anything after the prefix survives whole.
        assertEquals("abc 123", normalizePaxSenixApiKey("Bearer abc 123"))
    }

    @Test
    fun `an empty key is empty`() {
        assertEquals("", normalizePaxSenixApiKey(""))
        assertEquals("", normalizePaxSenixApiKey("   "))
    }
}

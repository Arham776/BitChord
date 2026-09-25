package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Sniffing the smaller providers' wire formats.
 *
 * The behaviour that matters is the one that used to fail silently: a body in a
 * format we do not recognise must produce *nothing*, not the raw text. A
 * provider that answered with a web page, an error, or a JSON envelope one level
 * deeper than expected used to end up rendered as lyric lines — and a lyric panel
 * that says "lyrics not found" in time with the music is worse than an empty one.
 */
class ProviderLyricsTest {

    // ---- Unwrapping --------------------------------------------------------

    @Test
    fun `a bare string is taken as it stands`() {
        assertEquals("hello", ProviderLyrics.unwrap("hello"))
    }

    @Test
    fun `a single json envelope is opened`() {
        assertEquals("hello", ProviderLyrics.unwrap("""{"lyrics":"hello"}"""))
    }

    @Test
    fun `two envelopes are opened`() {
        // Real: a host that wraps an API response in a convenience envelope.
        val body = """{"data":{"lyrics":"hello"}}"""
        assertEquals("hello", ProviderLyrics.unwrap(body))
    }

    @Test
    fun `a json string holding json is opened twice`() {
        assertEquals("hello", ProviderLyrics.unwrap("""{"data":"{\"lyrics\":\"hello\"}"}"""))
    }

    @Test
    fun `a fenced code block is unwrapped`() {
        val body = "```\nhello\n```"
        assertEquals("hello", ProviderLyrics.unwrap(body))
    }

    @Test
    fun `a byte order mark does not defeat it`() {
        assertEquals("hello", ProviderLyrics.unwrap("\uFEFFhello"))
    }

    @Test
    fun `nothing produces nothing`() {
        assertNull(ProviderLyrics.unwrap("   "))
    }

    // ---- Refusals ----------------------------------------------------------

    @Test
    fun `an ok-false envelope is a refusal rather than a lyric`() {
        // The failure this whole check exists for: the endpoint answered 200 with
        // a body saying it had nothing, and reading it as words put the message
        // on screen.
        assertNull(ProviderLyrics.unwrap("""{"ok":false,"lyrics":"nope"}"""))
    }

    @Test
    fun `an isError envelope is a refusal`() {
        assertNull(ProviderLyrics.unwrap("""{"isError":true,"lyrics":"nope"}"""))
    }

    @Test
    fun `an error field is a refusal`() {
        assertNull(ProviderLyrics.unwrap("""{"error":"quota exceeded","lyrics":"nope"}"""))
    }

    @Test
    fun `an empty error is not a refusal`() {
        // `"error": ""` and `"error": false` are how a healthy host says the
        // field is unused. Refusing those would refuse a working provider.
        assertEquals("hello", ProviderLyrics.unwrap("""{"error":"","lyrics":"hello"}"""))
        assertEquals("hello", ProviderLyrics.unwrap("""{"error":false,"lyrics":"hello"}"""))
    }

    @Test
    fun `a null error is not a refusal`() {
        assertEquals("hello", ProviderLyrics.unwrap("""{"error":null,"lyrics":"hello"}"""))
    }

    // ---- Format sniffing ---------------------------------------------------

    @Test
    fun `ttml is recognised and parsed`() {
        val ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
            <p begin="00:00:01.000" end="00:00:03.000">first line</p>
            </div></body></tt>
        """.trimIndent()
        val lines = ProviderLyrics.parse(ttml)
        assertEquals(1, lines?.size)
        assertEquals("first line", lines?.first()?.text)
    }

    @Test
    fun `escaped ttml is unescaped before parsing`() {
        // Some hosts return the document as a string *about* a document. Parsing
        // that as TTML finds nothing, and "no lines" reads as "no lyrics".
        val document = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>" +
            "<p begin=\"00:00:01.000\">first line</p>" +
            "</div></body></tt>"
        val escaped = document
            .replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
        val ttml = "{\"ttml\":\"$escaped\"}"
        val lines = ProviderLyrics.parse(ttml)
        assertEquals("first line", lines?.first()?.text)
    }

    @Test
    fun `enhanced lrc is recognised`() {
        val lrc = "[00:00.00]<00:00.00>Hello <00:00.50>world"
        val lines = ProviderLyrics.parse(lrc)
        assertTrue(lines != null && lines.isNotEmpty())
        assertTrue(lines.first().isWordSynced)
    }

    @Test
    fun `plain lrc is recognised`() {
        val lines = ProviderLyrics.parse("[00:00.00]first\n[00:02.00]second")
        assertEquals(2, lines?.size)
        assertEquals("first", lines?.first()?.text)
    }

    @Test
    fun `plain text is accepted with no timing`() {
        val lines = ProviderLyrics.parse("just some words\non two lines")
        assertEquals(2, lines?.size)
        assertTrue(lines?.all { it.timeMs == 0L } == true)
    }

    @Test
    fun `markup that is not ttml is refused rather than rendered`() {
        // Rendering HTML as lyrics is not a degraded answer, it is a wrong one.
        assertNull(ProviderLyrics.parse("<html><body><p>Not found</p></body></html>"))
    }

    @Test
    fun `a prose refusal is refused`() {
        assertNull(ProviderLyrics.parse("lyrics not found"))
        assertNull(ProviderLyrics.parse("Error: quota exceeded"))
    }

    @Test
    fun `lrc metadata tags are not lyrics`() {
        val lines = ProviderLyrics.parse("[ar:Some Artist]\n[ti:Some Title]\n[00:00.00]real line")
        assertEquals(1, lines?.size)
        assertEquals("real line", lines?.first()?.text)
    }

    @Test
    fun `a timed document whose lines are all blank is nothing`() {
        // A shape that is technically valid and has nothing to show.
        assertNull(ProviderLyrics.parse("[00:00.00]\n[00:02.00]  \n"))
    }
}

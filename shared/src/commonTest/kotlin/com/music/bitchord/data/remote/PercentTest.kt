package com.music.bitchord.data.remote

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Percent-encoding for one path segment.
 *
 * Round trips matter more than any single direction: an address is encoded on the way
 * to the server and decoded on the way back, and every name a listener sees is the
 * decoded one. A bug here is not a bad request — it is a library full of `BjÃ¶rk`.
 */
class PercentTest {

    // ---- Decoding ----------------------------------------------------------

    @Test
    fun `text with no escapes is itself`() {
        assertEquals("Pink Floyd - Time.flac", Percent.decode("Pink Floyd - Time.flac"))
        assertEquals("", Percent.decode(""))
    }

    @Test
    fun `a space is an escape and stays one`() {
        assertEquals("Pink Floyd", Percent.decode("Pink%20Floyd"))
        assertEquals("a b", Percent.decode("a%20b"))
    }

    @Test
    fun `a plus is a plus`() {
        // The form-decoder trap: `URLDecoder.decode` says "a+b" is "a b", and in a
        // path that renames the file.
        assertEquals("a+b", Percent.decode("a+b"))
        assertEquals("a b", Percent.decode("a%20b"))
    }

    @Test
    fun `a multi-byte character is decoded as one character`() {
        // `é` is two bytes and two escapes. Building the result a character at a time
        // gives `Ã©`, which matches no file and searches for nothing.
        assertEquals("é", Percent.decode("%C3%A9"))
        assertEquals("Björk - Jóga.flac", Percent.decode("Bj%C3%B6rk%20-%20J%C3%B3ga.flac"))
    }

    @Test
    fun `a character outside latin-1 is decoded too`() {
        assertEquals("日本語", Percent.decode("%E6%97%A5%E6%9C%AC%E8%AA%9E"))
    }

    @Test
    fun `an escape mixed with plain text is decoded where it is`() {
        assertEquals("a-b-c", Percent.decode("a%2Db-c"))
        assertEquals("100% pure", Percent.decode("100%25%20pure"))
    }

    @Test
    fun `a malformed escape is passed through rather than lost`() {
        // A literal `%` in a filename is allowed by most filesystems, and dropping or
        // failing on it renames the file in the listener's own library view.
        assertEquals("50%off", Percent.decode("50%off"))
        assertEquals("50%zz", Percent.decode("50%zz"))
        assertEquals("a%", Percent.decode("a%"))
        assertEquals("a%2", Percent.decode("a%2"))
    }

    @Test
    fun `lower case escapes are escapes`() {
        // Servers are inconsistent about this and a hand-typed address may be either.
        assertEquals("é", Percent.decode("%c3%a9"))
    }

    // ---- Encoding ----------------------------------------------------------

    @Test
    fun `a path-safe name is left alone`() {
        assertEquals("Time.flac", Percent.encodeSegment("Time.flac"))
        assertEquals("AlbumArt2.png", Percent.encodeSegment("AlbumArt2.png"))
        assertEquals("a-b_c~d", Percent.encodeSegment("a-b_c~d"))
    }

    @Test
    fun `a space is percent twenty and never a plus`() {
        assertEquals("Pink%20Floyd", Percent.encodeSegment("Pink Floyd"))
        assertEquals("a%20b", Percent.encodeSegment("a b"))
    }

    @Test
    fun `the characters that would change a path are escaped`() {
        // Each of these silently changes the path if it arrives raw, which is why they
        // are escaped rather than passed through.
        assertEquals("a%23b", Percent.encodeSegment("a#b"))
        assertEquals("a%3Fb", Percent.encodeSegment("a?b"))
        assertEquals("a%22b", Percent.encodeSegment("a\"b"))
        assertEquals("a%2Fb", Percent.encodeSegment("a/b"))
        assertEquals("a%5Cb", Percent.encodeSegment("a\\b"))
    }

    @Test
    fun `a plus is left alone because it is a legal path character`() {
        // Escaping it would be defensible; not escaping it is what every server
        // expects, and `%2B` decodes back to the same character either way.
        assertEquals("AC+DC", Percent.encodeSegment("AC+DC"))
    }

    @Test
    fun `a non-ascii name is encoded a byte at a time`() {
        assertEquals("Bj%C3%B6rk%20-%20J%C3%B3ga.flac", Percent.encodeSegment("Björk - Jóga.flac"))
    }

    @Test
    fun `an empty segment stays empty`() {
        assertEquals("", Percent.encodeSegment(""))
    }

    // ---- Both ways ---------------------------------------------------------

    @Test
    fun `every name round trips`() {
        listOf(
            "Time.flac",
            "Pink Floyd - Time.flac",
            "AC+DC - Back.flac",
            "Björk - Jóga.flac",
            "100% Pure - Anthems.flac",
            "日本語 - 歌.flac",
            "50%off.flac",
            "a#b?c.flac",
            "Led Zeppelin - Stairway to Heaven (Remaster).flac",
        ).forEach { name ->
            assertEquals(name, Percent.decode(Percent.encodeSegment(name)), "did not survive: $name")
        }
    }
}

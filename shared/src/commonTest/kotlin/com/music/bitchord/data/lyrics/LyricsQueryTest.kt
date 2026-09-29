package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The title cleaner every source is asked with.
 *
 * The asymmetry it encodes is the whole point and is easy to get wrong in the
 * tidying direction: removing more than this makes a search for one recording
 * into a search for another, and the result is the wrong words scrolling in time
 * with the right song. A miss is recoverable; that is not.
 */
class LyricsQueryTest {

    @Test
    fun `a plain title is left alone`() {
        assertEquals("Dracula", "Dracula".forLyricsSearch())
    }

    @Test
    fun `bracketed credits go · because they are not part of the name` () {
        assertEquals("Dracula", "Dracula (feat. JENNIE)".forLyricsSearch())
        assertEquals("Anti-Hero", "Anti-Hero [ft. Taylor Swift]".forLyricsSearch())
        assertEquals("Sunset", "Sunset (with Caroline Polachek)".forLyricsSearch())
    }

    @Test
    fun `unbracketed credits go · and take the rest of the title with them` () {
        // "… feat. Someone" runs to the end, so the tail is dropped whole.
        assertEquals("Ordinary", "Ordinary feat. Sam Fischer".forLyricsSearch())
    }

    @Test
    fun `upload packaging goes`() {
        assertEquals("Ordinary", "Ordinary (Official Video)".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary [Official Music Video]".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary (Lyrics)".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary (Audio)".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary (4K)".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary (HD)".forLyricsSearch())
        assertEquals("Ordinary", "Ordinary (Official)".forLyricsSearch())
    }

    @Test
    fun `artist-prefixed YouTube audio titles reduce to the catalog title`() {
        assertEquals(
            "FORTY",
            "AIKA & NAHREEL FORTY (AUDIO) FT AZAWI".forLyricsSearch("Aika & Nahreel, Azawi"),
        )
        assertEquals(
            "Forty",
            "Aika & Nahreel - Forty (Official Audio) ft. Azawi".forLyricsSearch("Aika & Nahreel, Azawi"),
        )
        // A one-word artist at the start is ambiguous without upload punctuation.
        assertEquals("Aika Song", "Aika Song".forLyricsSearch("Aika"))
    }

    @Test
    fun `featured artists in a YouTube title do not pollute Swalla lookup`() {
        assertEquals(
            "Swalla",
            "Swalla (feat. Nicki Minaj & Ty Dolla \$ign)".forLyricsSearch(
                "Jason Derulo, Nicki Minaj, Ty Dolla \$ign",
            ),
        )
    }

    // ---- What must survive -------------------------------------------------

    @Test
    fun `a remix stays · because it names a different recording` () {
        assertEquals("Song (Remix)", "Song (Remix)".forLyricsSearch())
        assertEquals("Song (Acoustic)", "Song (Acoustic)".forLyricsSearch())
        assertEquals("Song (Live)", "Song (Live)".forLyricsSearch())
        assertEquals("Song (Sped Up)", "Song (Sped Up)".forLyricsSearch())
    }

    @Test
    fun `a remaster stays · and so does a year in the name` () {
        // "(Remastered 2011)" looks exactly like "(feat. X)" and means the
        // opposite: same recording, different master. Stripping it would search
        // for the wrong master, which is the near-miss case this is guarding.
        assertEquals("Song (Remastered 2011)", "Song (Remastered 2011)".forLyricsSearch())
    }

    @Test
    fun `credits and packaging go together without eating the recording`() {
        // The combination that actually occurs: credits first, then packaging.
        assertEquals(
            "Anti-Hero",
            "Anti-Hero (feat. Taylor Swift) (Official Music Video)".forLyricsSearch(),
        )
    }

    @Test
    fun `a remix with credits keeps the remix and loses the credits`() {
        assertEquals("Song (Live)", "Song (feat. X) (Live)".forLyricsSearch())
    }

    // ---- Shape -------------------------------------------------------------

    @Test
    fun `whitespace is collapsed and the ends trimmed`() {
        assertEquals("Song Title", "  Song   Title  ".forLyricsSearch())
        assertEquals("Song", "Song - ".forLyricsSearch())
        assertEquals("Song", "Song \u2014 ".forLyricsSearch())
    }

    @Test
    fun `a title that was only packaging falls back to what we were given`() {
        // Asking with the original is better than asking with nothing, and the
        // provider may well have it filed with the noise still on.
        val packaging = "(Official Video)".forLyricsSearch()
        assertEquals("(Official Video)", packaging)
    }

    @Test
    fun `an empty title stays empty rather than becoming blank-with-noise`() {
        assertEquals("", "".forLyricsSearch())
    }

    // ---- The artist --------------------------------------------------------

    @Test
    fun `an auto-generated channel name is trimmed`() {
        assertEquals("Tame Impala", "Tame Impala - Topic".artistForLyricsSearch())
    }

    @Test
    fun `a real artist with a Topic suffix in the middle is untouched`() {
        // Only the whole-string suffix is packaging; a band can be called this.
        assertEquals("Topic", "Topic".artistForLyricsSearch())
        assertEquals("Two - Topic Bands", "Two - Topic Bands".artistForLyricsSearch())
    }

    @Test
    fun `an artist that was only the suffix is not lost`() {
        // Stripping the suffix leaves nothing, so the trimmed original is used
        // rather than an empty artist — which no provider would have.
        assertEquals("- Topic", " - Topic".artistForLyricsSearch())
    }

    // ---- Whether to ask at all --------------------------------------------

    @Test
    fun `a blank query is not worth a request`() {
        assertFalse("".isUsableLyricsQuery())
        assertFalse("   ".isUsableLyricsQuery())
    }

    @Test
    fun `a one-character title is a real thing and is asked about`() {
        // Refusing it would be tidiness that loses a match.
        assertTrue("X".isUsableLyricsQuery())
    }
}

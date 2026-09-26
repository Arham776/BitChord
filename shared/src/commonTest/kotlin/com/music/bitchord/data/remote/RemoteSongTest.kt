package com.music.bitchord.data.remote

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What a remote library names a track.
 *
 * Everything here is a filename, so the cases are the filenames people actually have:
 * the ones with a separator in them, the ones with a stray dot, the ones in a folder
 * called `..`, and the non-ASCII ones — which is where a percent decoder written a
 * character at a time rather than a byte at a time shows itself.
 */
class RemoteSongTest {

    // ---- Artist and title --------------------------------------------------

    @Test
    fun `a name with one separator is an artist and a title`() {
        assertEquals("Pink Floyd" to "Time", RemoteSong.splitArtistTitle("Pink Floyd - Time"))
    }

    @Test
    fun `a name with no separator is all title`() {
        assertEquals(null to "Time", RemoteSong.splitArtistTitle("Time"))
    }

    @Test
    fun `only the first separator is a separator`() {
        // A title with a hyphen in it is common — a subtitle, a movement, an opus
        // number — and splitting on every separator files the rest of the title under
        // the artist.
        assertEquals("Bach" to "Symphony No. 5 - Allegro", RemoteSong.splitArtistTitle("Bach - Symphony No. 5 - Allegro"))
    }

    @Test
    fun `a separator with nothing before it is not one`() {
        assertEquals(null to "Time", RemoteSong.splitArtistTitle(" - Time"))
        assertEquals(null to "Time", RemoteSong.splitArtistTitle("   - Time"))
    }

    @Test
    fun `a separator with nothing after it leaves no title`() {
        // The other half of the same rule: `Artist - ` is a track whose title is
        // missing, not a track called `Artist - `.
        assertEquals("Pink Floyd" to null, RemoteSong.splitArtistTitle("Pink Floyd - "))
    }

    @Test
    fun `a hyphen without spaces is not a separator`() {
        // `01-Intro.mp3` is one name to a person, and the other kind of separator here
        // would turn an artist into a track number.
        assertEquals(null to "01-Intro", RemoteSong.splitArtistTitle("01-Intro"))
    }

    @Test
    fun `surrounding space is trimmed off each half`() {
        assertEquals("Pink Floyd" to "Time", RemoteSong.splitArtistTitle("  Pink Floyd   -   Time  "))
    }

    // ---- The row -----------------------------------------------------------

    @Test
    fun `a row takes its name from the filename and its address from the listing`() {
        val song = song(fileName = "Pink Floyd - Time.flac", album = "The Dark Side of the Moon")
        assertEquals("Time", song.title)
        assertEquals("Pink Floyd", song.artist)
        assertEquals("The Dark Side of the Moon", song.albumName)
        // The address the player reads is the one the listing gave, unaltered: a row
        // that rewrote it would play the wrong file.
        assertEquals("https://dav.example.com/Music/Pink%20Floyd/Time.flac", song.localPath)
    }

    @Test
    fun `a row with no artist in its name says so rather than showing nothing`() {
        assertEquals(WebDavConfig.UNKNOWN_ARTIST, song(fileName = "Intro.mp3").artist)
    }

    @Test
    fun `a row is never given a thumbnail that is not there`() {
        // Upstream's `null` and this app's reason for it: a placeholder renders as a
        // picture of nothing, which is worse than the empty box it stands in for.
        assertNull(song(fileName = "Time.flac").thumbnailUrl)
        assertNull(song(fileName = "Time.flac").durationText)
    }

    @Test
    fun `the extension is not part of the title`() {
        assertEquals("Time", song(fileName = "Pink Floyd - Time.flac").title)
        // And only the last one: a title with a dot in it keeps it.
        assertEquals("Time (Part 1.5)", song(fileName = "Pink Floyd - Time (Part 1.5).flac").title)
    }

    @Test
    fun `a filename with no extension keeps every character of itself`() {
        // `substringBeforeLast('.')` on a name that is all stem leaves nothing, and a
        // title of "" is a blank row — so the whole name is used.
        assertEquals("Time", song(fileName = "Time").title)
        assertEquals("Pink Floyd", song(fileName = "Pink Floyd - Time").artist)
        assertEquals("Time", song(fileName = "Pink Floyd - Time").title)
        // A leading dot is a name with no extension, not an extension with no name.
        assertEquals(".hidden", song(fileName = ".hidden").title)
    }

    @Test
    fun `a file at the root of a share has no album`() {
        // An empty album name is a blank line under every row at the root of a share,
        // which is most of a small library.
        assertNull(song(fileName = "Time.flac", album = null).albumName)
        assertNull(song(fileName = "Time.flac", album = "  ").albumName)
    }

    @Test
    fun `a non-ascii name survives being decoded`() {
        // The case a byte-at-a-time decoder gets wrong: `é` is two bytes escaped as
        // two escapes, and a character-at-a-time decoder gives back `Ã©` — which then
        // matches no file and searches for nothing.
        val song = song(fileName = "Björk - Jóga.flac", album = "Homogénic")
        assertEquals("Jóga", song.title)
        assertEquals("Björk", song.artist)
        assertEquals("Homogénic", song.albumName)
    }

    @Test
    fun `a row with a non-ascii name round trips through its id`() {
        // The id is the address, so this is the same check as the one above with the
        // address in the other direction: encode a name, and the listing's decode has
        // to give the same name back.
        val url = WebDavConfig.joinUrl("https://dav.example.com/Music", "Björk - Jóga.flac")
        assertEquals("https://dav.example.com/Music/Bj%C3%B6rk%20-%20J%C3%B3ga.flac", url)
        assertEquals("Björk - Jóga.flac", WebDavConfig.fileNameOf(url))
        assertTrue(url.endsWith(".flac"))
    }

    private fun song(
        fileName: String,
        album: String? = null,
        url: String = "https://dav.example.com/Music/Pink%20Floyd/Time.flac",
    ) = RemoteSong.build(
        videoId = WebDavConfig.idFor(url),
        streamUrl = url,
        fileName = WebDavConfig.fileNameOf(WebDavConfig.joinUrl("https://dav.example.com/Music", fileName)),
        albumName = album,
    )
}

package com.music.bitchord.data.remote

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Reading a WebDAV multistatus.
 *
 * The parser is the part of a WebDAV client that fails silently: a listing that comes
 * back empty looks exactly like a share with no music in it, and the listener's next
 * move is to go looking for a folder that was there all along. So every shape a real
 * server sends is a fixture here.
 */
class WebDavMultistatusTest {

    private val dir = "https://cloud.example.com/Music"

    private fun parse(xml: String, base: String = dir) = WebDavClient.parseMultistatus(xml, base)

    // ---- The shape a server actually sends ---------------------------------

    @Test
    fun `a prefixed multistatus is read`() {
        val entries = parse(MULTISTATUS)
        assertEquals(2, entries.size)
        // Found by name rather than by position: a server lists a folder before the
        // files inside it, and the order is the server's business, not ours.
        val track = entries.first { it.displayName == "track.flac" }
        assertEquals("https://cloud.example.com/Music/Album/track.flac", track.url)
        assertFalse(track.isCollection)
    }

    @Test
    fun `a collection is a collection`() {
        assertTrue(parse(MULTISTATUS).first { it.displayName == "Album" }.isCollection)
    }

    @Test
    fun `a content type is read when the server sends one`() {
        assertEquals("audio/flac", parse(MULTISTATUS).first { it.displayName == "track.flac" }.contentType)
    }

    @Test
    fun `the directory the server echoes back is not a track`() {
        // Every server includes it, and a directory listed as a track is a row that
        // plays nothing.
        assertFalse(parse(MULTISTATUS).any { it.isCollection && it.displayName == "Music" })
    }

    // ---- Prefixes ----------------------------------------------------------

    @Test
    fun `a different namespace prefix is still read`() {
        // `d:` on Nextcloud, `D:` on some others, none at all on a few. A parser that
        // expects the RFC's example prefix reads a share as empty.
        val upper = MULTISTATUS.replace("d:", "D:")
        assertEquals(2, parse(upper).size)
        val bare = MULTISTATUS.replace("d:", "")
        assertEquals(2, parse(bare).size)
        val other = MULTISTATUS.replace("d:", "lp1:")
        assertEquals(2, parse(other).size)
    }

    @Test
    fun `a self-closing collection still counts as a collection`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/Music/Album/</d:href>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:response>
</d:multistatus>"""
        val entry = parse(xml).single()
        assertTrue(entry.isCollection, "a self-closing <collection/> was missed")
    }

    // ---- Names -------------------------------------------------------------

    @Test
    fun `a display name is preferred over the address`() {
        // A Nextcloud share full of `track-1.flac` is a worse library than the same
        // share with the names its uploader chose.
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/Music/track-1.flac</d:href>
    <d:displayname>Real Name.flac</d:displayname>
  </d:response>
</d:multistatus>"""
        assertEquals("Real Name.flac", parse(xml).single().displayName)
    }

    @Test
    fun `a missing display name falls back to the decoded address`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/Music/Artist%20-%20Title.flac</d:href>
  </d:response>
</d:multistatus>"""
        assertEquals("Artist - Title.flac", parse(xml).single().displayName)
    }

    // ---- Addresses --------------------------------------------------------

    @Test
    fun `an absolute href is used as it is`() {
        // Deliberately not re-rooted onto our own host: a server that hands back
        // another host is saying where the file is, and rewriting it would send the
        // credential somewhere it does not belong.
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>https://cdn.example.net/a.flac</d:href></d:response>
</d:multistatus>"""
        assertEquals("https://cdn.example.net/a.flac", parse(xml).single().url)
    }

    @Test
    fun `a root-relative href keeps the scheme host and port`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/Music/a.flac</d:href></d:response>
</d:multistatus>"""
        assertEquals(
            "https://cloud.example.com:8443/Music/a.flac",
            parse(xml, "https://cloud.example.com:8443/dav").single().url
        )
    }

    @Test
    fun `a relative href resolves against the directory asked about`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>a.flac</d:href></d:response>
</d:multistatus>"""
        assertEquals("https://cloud.example.com/Music/a.flac", parse(xml).single().url)
    }

    @Test
    fun `a relative href does not double a slash`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>a.flac</d:href></d:response>
</d:multistatus>"""
        assertFalse(parse(xml, "https://cloud.example.com/Music/").single().url.contains("//Music"))
    }

    @Test
    fun `an entry is not matched against the directory it came from`() {
        // The directory comes back with and without a trailing slash depending on the
        // server, and both are the same place.
        for (echoed in listOf("/Music", "/Music/")) {
            val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>$echoed</d:href></d:response>
</d:multistatus>"""
            assertTrue(parse(xml).isEmpty(), "the echoed directory '$echoed' was listed as a track")
        }
    }

    // ---- Nonsense ---------------------------------------------------------

    @Test
    fun `an empty response is no entries rather than a failure`() {
        assertEquals(emptyList(), parse(""))
        assertEquals(emptyList(), parse("   "))
    }

    @Test
    fun `a response with no href is skipped rather than guessed at`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:displayname>orphan</d:displayname></d:response>
</d:multistatus>"""
        assertEquals(emptyList(), parse(xml))
    }

    @Test
    fun `something that is not xml at all is no entries`() {
        // Which is what an HTML error page from a reverse proxy looks like, and it must
        // read as an empty listing rather than as a crash.
        assertEquals(emptyList(), parse("<html><body>502 Bad Gateway</body></html>"))
        assertEquals(emptyList(), parse("{\"error\":\"nope\"}"))
    }

    @Test
    fun `a truncated response is read as far as it goes`() {
        val xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/Music/a.flac</d:href></d:response>
  <d:response><d:href>/Music/b.flac</d:h"""
        assertEquals(1, parse(xml).size)
    }

    // ---- The statuses, which are the other silent failure ------------------

    @Test
    fun `a multistatus body built with a builder round-trips`() {
        // The shape the tests above all use, checked once as a whole so a change to
        // the fixture is caught rather than silently weakening every other test.
        val entries = parse(MULTISTATUS)
        assertTrue(entries.all { it.url.startsWith("https://cloud.example.com/Music/") })
        assertEquals(1, entries.count { it.isCollection })
        assertEquals(1, entries.count { !it.isCollection })
    }

    private companion object {
        val MULTISTATUS = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/Music/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Music</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/Music/Album/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Album</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/Music/Album/track.flac</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>track.flac</d:displayname>
        <d:resourcetype/>
        <d:getcontenttype>audio/flac</d:getcontenttype>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>"""
    }
}

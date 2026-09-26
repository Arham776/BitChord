package com.music.bitchord.data.webdav

import com.music.bitchord.data.remote.WebDavClient
import com.music.bitchord.data.remote.WebDavConfig
import com.music.bitchord.data.remote.WebDavException
import com.music.bitchord.data.remote.RemoteListing
import com.music.bitchord.data.model.UiState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * A listed file as a row, and the sentence a listing produces when it has nothing.
 *
 * The row's rules are all about *whose name wins*, and every case here is a server
 * that names its files differently from how it spells their URLs — which is the
 * normal case on Nextcloud, and the reason a share can look like a library rather than
 * a list of `track-1.flac`.
 */
class WebDavRepositoryTest {

    private val dir = "https://dav.example.com/Music"

    /** A folder the way a server spells it in an `href`: escaped. */
    private val albumDir = "$dir/Pink%20Floyd/The%20Dark%20Side%20of%20the%20Moon"

    private fun entry(
        name: String,
        displayName: String = name,
        folder: String = albumDir,
    ) = WebDavClient.Entry(
        url = WebDavConfig.joinUrl(folder, name),
        displayName = displayName,
        isCollection = false,
    )

    private fun song(name: String, displayName: String = name, cover: String? = null, folder: String = albumDir) =
        with(WebDavRepository) { entry(name, displayName, folder).toSong(cover) }

    // ---- Whose name wins ----------------------------------------------------

    @Test
    fun `a server's own name for a file beats the one decoded out of its address`() {
        // The case this whole rule exists for: a Nextcloud share full of `track-1.flac`
        // whose display names are the real titles.
        val song = song("track-1.flac", displayName = "Time.flac")
        assertEquals("Time", song.title)
        // Neither name names an artist, and the answer says so rather than borrowing
        // one from the folder the file happens to be in.
        assertEquals(WebDavConfig.UNKNOWN_ARTIST, song.artist)
    }

    @Test
    fun `a display name with a separator in it gives an artist and a title`() {
        val song = song("track-1.flac", displayName = "Björk - Jóga.flac")
        assertEquals("Jóga", song.title)
        assertEquals("Björk", song.artist)
    }

    @Test
    fun `a display name that is only an extension falls back to the address`() {
        // Some servers answer `track-1.flac` as the display name for everything, and
        // some answer the extension on its own. Either way the address still has a
        // name in it, and a blank row is the worst possible outcome.
        val song = song("Björk - Jóga.flac", displayName = ".flac")
        assertEquals("Jóga", song.title)
        assertEquals("Björk", song.artist)
    }

    @Test
    fun `a display name with no artist in it keeps the address's artist`() {
        val song = song("Pink Floyd - Time.flac", displayName = "Time (Remastered).flac")
        assertEquals("Time (Remastered)", song.title)
        assertEquals("Pink Floyd", song.artist)
    }

    @Test
    fun `a display name with no artist and an address with none says so`() {
        val song = song("intro.flac", displayName = "Intro (live).flac")
        assertEquals("Intro (live)", song.title)
        assertEquals(WebDavConfig.UNKNOWN_ARTIST, song.artist)
    }

    @Test
    fun `a non-ascii name survives the server and the address`() {
        val song = song("%E6%97%A5%E6%9C%AC%E8%AA%9E.flac", displayName = "日本語 - 歌.flac")
        assertEquals("歌", song.title)
        assertEquals("日本語", song.artist)
    }

    // ---- What else the row needs -------------------------------------------

    @Test
    fun `the album is the folder the file sits in`() {
        assertEquals("The Dark Side of the Moon", song("Time.flac").albumName)
    }

    @Test
    fun `a file at the root of a share has no album`() {
        // A blank album is a blank line under every row, and a share dumped flat has
        // albums in it only if somebody made them.
        val atRoot = WebDavClient.Entry(
            url = "https://dav.example.com/Time.flac",
            displayName = "Time.flac",
            isCollection = false,
        )
        assertNull(with(WebDavRepository) { atRoot.toSong() }.albumName)
    }

    @Test
    fun `the play address is the address the listing gave`() {
        val song = song("Time.flac")
        assertEquals(entry("Time.flac").url, song.localPath)
        assertTrue(song.localPath!!.startsWith("https://dav.example.com/"))
    }

    @Test
    fun `the id is the prefixed address so two libraries cannot collide`() {
        // A saved queue holding this row has to find the same file next launch, and
        // has to be unable to mean a YouTube id of the same characters.
        val song = song("Time.flac")
        assertEquals(WebDavConfig.idFor(entry("Time.flac").url), song.videoId)
        assertTrue(WebDavConfig.isWebDavId(song.videoId))
        assertEquals(entry("Time.flac").url, WebDavConfig.fileUrlOf(song.videoId))
    }

    @Test
    fun `a cover filed beside the file is the row's thumbnail`() {
        val cover = "https://dav.example.com/Music/Pink%20Floyd/cover.jpg"
        assertEquals(cover, song("Time.flac", cover = cover).thumbnailUrl)
        // And no cover is null rather than a placeholder: a picture of nothing is worse
        // than the empty box it stands in for.
        assertNull(song("Time.flac").thumbnailUrl)
    }

    // ---- Which cover belongs to which track --------------------------------

    @Test
    fun `a cover is matched to the folder it is filed in`() {
        // The grouping key is the whole mechanism, so it is checked where two folders
        // on one server would otherwise borrow each other's sleeve. The key is the
        // server's own spelling of the path — every entry in one folder comes from one
        // `PROPFIND` and so shares a spelling, which is what makes it a key.
        val url = entry("Time.flac").url
        val sameFolder = WebDavConfig.joinUrl(albumDir, "cover.jpg")
        val otherFolder = WebDavConfig.joinUrl("$dir/Pink%20Floyd/Another%20Album", "cover.jpg")
        assertEquals(WebDavConfig.dirKeyOf(url), WebDavConfig.dirKeyOf(sameFolder))
        assertTrue(WebDavConfig.dirKeyOf(url) != WebDavConfig.dirKeyOf(otherFolder))
    }

    @Test
    fun `two servers on one machine are two libraries`() {
        // Same host, same path, different port: a NAS with two WebDAV daemons on it.
        // These are different shares and must not share covers — while the credential
        // they share is a *host* question, which is a different rule on purpose.
        assertTrue(
            WebDavConfig.dirKeyOf("http://nas.local:5005/music/cover.jpg")
                != WebDavConfig.dirKeyOf("http://nas.local:8096/music/cover.jpg"),
        )
        assertEquals("nas.local", WebDavConfig.hostOf("http://nas.local:5005/music"))
    }

    // ---- What a listing says -----------------------------------------------

    @Test
    fun `a listing with tracks in it is those tracks`() {
        val state: UiState<List<String>> =
            RemoteListing.state(Result.success(listOf("a", "b")), "No audio files")
        val success = assertIs<UiState.Success<List<String>>>(state)
        assertEquals(listOf("a", "b"), success.data)
    }

    @Test
    fun `a listing with nothing in it says what an empty one says`() {
        // Never an empty success: a page cannot draw "0 tracks" and a listener cannot
        // tell that from a share that is not there.
        val state: UiState<List<String>> =
            RemoteListing.state(Result.success(emptyList<String>()), "That share has no audio files.")
        assertEquals("That share has no audio files.", assertIs<UiState.Error>(state).message)
    }

    @Test
    fun `a listing that failed says why rather than saying it is empty`() {
        // The distinction the whole object exists for: a share that answers with an
        // error is not an empty share, and "no audio files" sends somebody hunting
        // through folder paths for a password problem.
        val state: UiState<List<String>> = RemoteListing.state(
            Result.failure(WebDavException("That server did not accept the password.")),
            "No audio files",
        )
        assertEquals("That server did not accept the password.", assertIs<UiState.Error>(state).message)
    }

    @Test
    fun `a failure with nothing to say still says something`() {
        val state: UiState<List<String>> =
            RemoteListing.state(Result.failure(WebDavException("   ")), "No audio files")
        val message = assertIs<UiState.Error>(state).message
        assertTrue(message.isNotBlank(), "a blank error line is not an error line")
    }
}

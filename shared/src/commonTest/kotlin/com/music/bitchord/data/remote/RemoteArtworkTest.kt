package com.music.bitchord.data.remote

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Which of the pictures in a folder is the album's cover.
 *
 * The whole feature is a judgement about a folder of strangers' files, so the cases
 * are the folders people actually have: a download manager's `IMG_1234.jpg`, a
 * `cover` with a suffix, and a folder with nothing that looks like a cover at all.
 */
class RemoteArtworkTest {

    // ---- Picking -----------------------------------------------------------

    @Test
    fun `a cover named as one wins over the rest`() {
        // Upstream's three, verbatim: the point of preferring a name is that a folder
        // is full of `IMG_1234.jpg` from a download manager.
        assertEquals("https://dav.example.com/a/cover.jpg", RemoteArtwork.pick(listOf(
            "https://dav.example.com/a/IMG_1234.jpg",
            "https://dav.example.com/a/cover.jpg",
            "https://dav.example.com/a/back.jpg",
        )))
    }

    @Test
    fun `nothing that looks like a cover is no cover`() {
        // `[z.jpg, a.jpg]` must not answer `a.jpg` on alphabetical order alone: a
        // listener who sees a cover has no way to know it is the wrong one, and no
        // cover at all is an honest answer.
        assertEquals("https://dav.example.com/a/a.jpg", RemoteArtwork.pick(listOf(
            "https://dav.example.com/a/z.jpg",
            "https://dav.example.com/a/a.jpg",
        )))
    }

    @Test
    fun `an empty folder has no cover`() {
        assertNull(RemoteArtwork.pick(emptyList()))
    }

    @Test
    fun `every other conventional name is preferred to a stray one`() {
        val names = listOf("cover", "folder", "front", "albumart", "album", "artwork")
        names.forEach { name ->
            assertEquals(
                "https://dav.example.com/a/$name.jpg",
                RemoteArtwork.pick(listOf("https://dav.example.com/a/IMG_1234.jpg", "https://dav.example.com/a/$name.jpg")),
                "cover lost to IMG_1234 for a file called $name.jpg",
            )
        }
    }

    @Test
    fun `a name that starts with a conventional one still counts`() {
        assertEquals("https://dav.example.com/a/cover-front.png", RemoteArtwork.pick(listOf(
            "https://dav.example.com/a/scan.png",
            "https://dav.example.com/a/cover-front.png",
        )))
    }

    @Test
    fun `a word that merely contains one does not count`() {
        // `the cover.jpg` is a scan somebody named by hand, and matching on "contains"
        // would promote it over an `album.jpg` that is really the sleeve. A prefix is
        // the right test because `cover-front.jpg` and `AlbumArt2.png` are real.
        assertEquals("https://dav.example.com/a/album.jpg", RemoteArtwork.pick(listOf(
            "https://dav.example.com/a/the cover.jpg",
            "https://dav.example.com/a/album.jpg",
        )))
    }

    @Test
    fun `the order the server listed the folder in does not matter`() {
        // A WebDAV server is free to answer the same listing in a different order
        // between two launches, so a cover that changed on relaunch would be a cover
        // that flickers in a list.
        val folder = listOf(
            "https://dav.example.com/a/z.jpg",
            "https://dav.example.com/a/cover.jpg",
            "https://dav.example.com/a/IMG_1234.jpg",
        )
        val orderings = listOf(
            folder,
            folder.reversed(),
            listOf(folder[1], folder[2], folder[0]),
            listOf(folder[2], folder[0], folder[1]),
        )
        val answers = orderings.map { RemoteArtwork.pick(it) }.toSet()
        assertEquals(setOf("https://dav.example.com/a/cover.jpg"), answers)
        assertEquals(setOf("https://dav.example.com/a/cover.jpg"), answers)
    }

    @Test
    fun `a name that is only different in case is still a name`() {
        // Cover.JPG is what a camera writes.
        assertEquals("https://dav.example.com/a/Cover.JPG", RemoteArtwork.pick(listOf(
            "https://dav.example.com/a/zzz.jpg",
            "https://dav.example.com/a/Cover.JPG",
        )))
    }

    // ---- The name a file is known by ---------------------------------------

    @Test
    fun `a stem is the filename without its extension`() {
        assertEquals("cover", RemoteArtwork.stem("https://dav.example.com/a/cover.jpg"))
        assertEquals("album art", RemoteArtwork.stem("https://dav.example.com/a/album%20art.png"))
    }

    @Test
    fun `a query or a fragment is not part of a name`() {
        // A listing that hands back a signed address — which is what an S3-backed
        // share does — has its query full of slashes and its own file name in it.
        assertEquals("cover", RemoteArtwork.stem("https://dav.example.com/a/cover.jpg?X-Amz-Signature=a/b"))
        assertEquals("cover", RemoteArtwork.stem("https://dav.example.com/a/cover.jpg#frag"))
    }

    @Test
    fun `a plus is a plus and not a space`() {
        // `java.net.URLDecoder`, which upstream uses, is a *form* decoder and says
        // otherwise. A file called `AC+DC - Back in Black.mp3` is common and a
        // `+`-as-space decoder renames it to `AC DC ...`, which then covers nothing.
        assertEquals("ac+dc - back", RemoteArtwork.stem("https://dav.example.com/a/AC%2BDC%20-%20Back.flac"))
        assertEquals("ac+dc - back", RemoteArtwork.stem("https://dav.example.com/a/AC+DC%20-%20Back.flac"))
    }

    @Test
    fun `a malformed escape is left as it is`() {
        // A literal `%` in a filename is allowed by most filesystems, and dropping or
        // failing on it renames the file in the listener's own library view.
        assertEquals("100% pure", RemoteArtwork.stem("https://dav.example.com/a/100%25%20pure.jpg"))
        assertEquals("50%off", RemoteArtwork.stem("https://dav.example.com/a/50%off.jpg"))
    }

    @Test
    fun `a name with several dots keeps all of it but the last`() {
        assertEquals("cover.small", RemoteArtwork.stem("https://dav.example.com/a/cover.small.jpg"))
    }
}

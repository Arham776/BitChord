package com.music.bitchord.data.library

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The ordering and filtering of a scanned local library.
 *
 * The two properties worth pinning are both about what happens at the edges: a
 * track with no date, and a search box with nothing in it. Both used to be
 * reasonable-looking implementations that were quietly wrong — one put undated
 * files at the top of a "Date Added" list, which claims something the data does not
 * say, and the other could return nothing for an empty box, which is
 * indistinguishable from an empty library.
 */
class LocalLibrarySortTest {

    private fun song(
        title: String,
        artist: String = "Someone",
        album: String = "An Album",
        added: Long? = null,
        modified: Long? = null,
        path: String = "/music/${title.lowercase()}.flac",
    ) = LocalSong(
        path = path,
        title = title,
        artist = artist,
        album = album,
        dateAddedSeconds = added,
        dateModifiedSeconds = modified,
    )

    private val library = listOf(
        song("Charlie", added = 300, modified = 900),
        song("alpha", added = 100, modified = 700),
        song("Bravo", added = 200, modified = 800),
    )

    // ---- Title ------------------------------------------------------------

    @Test
    fun `title ascending is case-insensitive`() {
        // Case-sensitive ordering puts every capitalised title together, which for
        // a library of mixed tags reads as random.
        assertEquals(
            listOf("alpha", "Bravo", "Charlie"),
            library.sortedForLibrary(LocalMusicSort.TITLE_ASC).map { it.title },
        )
    }

    @Test
    fun `title descending is the reverse`() {
        assertEquals(
            listOf("Charlie", "Bravo", "alpha"),
            library.sortedForLibrary(LocalMusicSort.TITLE_DESC).map { it.title },
        )
    }

    @Test
    fun `reverse title is also case-insensitive`() {
        // `compareByDescending { it.title.lowercase() }` rather than the reverse
        // of the ascending list, which would put the capitals in the wrong place.
        val mixed = listOf(song("b"), song("A"), song("c"))
        assertEquals(
            listOf("c", "b", "A"),
            mixed.sortedForLibrary(LocalMusicSort.TITLE_DESC).map { it.title },
        )
    }

    // ---- Dates ------------------------------------------------------------

    @Test
    fun `date added puts the newest first`() {
        assertEquals(
            listOf("Charlie", "Bravo", "alpha"),
            library.sortedForLibrary(LocalMusicSort.DATE_ADDED).map { it.title },
        )
    }

    @Test
    fun `date modified is a different order from date added`() {
        // The whole reason both exist: a file can be old and edited yesterday.
        val edited = listOf(
            song("A", added = 900, modified = 100),
            song("B", added = 100, modified = 900),
        )
        assertEquals(
            listOf("A", "B"),
            edited.sortedForLibrary(LocalMusicSort.DATE_ADDED).map { it.title },
        )
        assertEquals(
            listOf("B", "A"),
            edited.sortedForLibrary(LocalMusicSort.DATE_MODIFIED).map { it.title },
        )
    }

    @Test
    fun `a track with no date sorts last rather than first`() {
        // It has not been added most recently — it has no date at all. Putting it
        // at the top of a "Date Added" list claims something the data does not say.
        val undated = listOf(
            song("Undated", added = null),
            song("Recent", added = 500),
        )
        assertEquals(
            listOf("Recent", "Undated"),
            undated.sortedForLibrary(LocalMusicSort.DATE_ADDED).map { it.title },
        )
    }

    @Test
    fun `undated tracks are ordered among themselves by title`() {
        val undated = listOf(song("Zeta"), song("alpha"), song("Mid"))
        assertEquals(
            listOf("alpha", "Mid", "Zeta"),
            undated.sortedForLibrary(LocalMusicSort.DATE_ADDED).map { it.title },
        )
    }

    @Test
    fun `tracks with equal dates are ordered by title`() {
        // Otherwise the order of two files added in the same second is whatever the
        // file system happened to return, and it changes between scans.
        val sameDay = listOf(
            song("Zebra", added = 100),
            song("Apple", added = 100),
        )
        assertEquals(
            listOf("Apple", "Zebra"),
            sameDay.sortedForLibrary(LocalMusicSort.DATE_ADDED).map { it.title },
        )
    }

    // ---- Search -----------------------------------------------------------

    @Test
    fun `every field is searched`() {
        // People look for a track by whichever of the three they remember.
        assertTrue(song("Zebra").matchesSearch("zebra"))
        assertTrue(song("Zebra", artist = "The Beatles").matchesSearch("beatles"))
        assertTrue(song("Zebra", album = "Abbey Road").matchesSearch("abbey"))
    }

    @Test
    fun `search ignores case`() {
        assertTrue(song("Zebra Crossing").matchesSearch("ZEBRA"))
        assertTrue(song("Zebra Crossing").matchesSearch("crossing"))
    }

    @Test
    fun `a blank query matches everything`() {
        // An empty box showing nothing is indistinguishable from an empty library.
        assertTrue(song("Anything").matchesSearch(""))
        assertTrue(song("Anything").matchesSearch("   "))
    }

    @Test
    fun `a query that matches nothing matches nothing`() {
        assertFalse(song("Zebra").matchesSearch("apples"))
    }

    @Test
    fun `a partial word matches`() {
        assertTrue(song("Extraordinary Machine").matchesSearch("mach"))
    }

    // ---- The two together -------------------------------------------------

    @Test
    fun `filtering happens before the ordering is applied`() {
        val result = library.libraryView(LocalMusicSort.TITLE_ASC, query = "a")
        assertEquals(listOf("alpha", "Bravo", "Charlie"), result.map { it.title })
    }

    @Test
    fun `filtering by artist narrows to that artist's tracks`() {
        val mixed = listOf(
            song("One", artist = "First"),
            song("Two", artist = "Second"),
            song("Three", artist = "First"),
        )
        assertEquals(
            listOf("One", "Three"),
            mixed.libraryView(LocalMusicSort.TITLE_ASC, query = "first").map { it.title },
        )
    }

    @Test
    fun `a query matching nothing gives an empty list rather than everything`() {
        assertEquals(0, library.libraryView(LocalMusicSort.TITLE_ASC, "zzzz").size)
    }

    @Test
    fun `an empty library is an empty list for every order`() {
        val empty = emptyList<LocalSong>()
        for (order in LocalMusicSort.entries) {
            assertEquals(0, empty.sortedForLibrary(order).size)
            assertEquals(0, empty.libraryView(order, "anything").size)
        }
    }

    // ---- Labels -----------------------------------------------------------

    @Test
    fun `every order has a name`() {
        // A sort menu with a blank row is a sort menu somebody cannot use.
        for (order in LocalMusicSort.entries) {
            assertTrue(order.label.isNotBlank())
        }
    }
}

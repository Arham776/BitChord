package com.music.bitchord.data.library

import kotlinx.serialization.Serializable

/**
 * Ordering for a scanned local library.
 *
 * Title first because that is what people look for a track by. The two date
 * orders are for the other question — *what did I just add* — and they are the
 * only reason a local file list needs sorting at all, since a scan has no
 * meaningful order of its own.
 */
enum class LocalMusicSort {
    TITLE_ASC,
    TITLE_DESC,
    DATE_ADDED,
    DATE_MODIFIED,
    ;

    val label: String
        get() = when (this) {
            TITLE_ASC -> "Title"
            TITLE_DESC -> "Title (Reverse)"
            DATE_ADDED -> "Date Added"
            DATE_MODIFIED -> "Date Modified"
        }
}

/**
 * How a local track is presented.
 *
 * A list for browsing and for its row affordances; a grid for the case where the
 * point is to *see* the collection — artwork, at a glance. Offering only one
 * makes the other somebody's habit rather than their choice.
 */
enum class LocalViewType {
    LIST,
    GRID,
}

/**
 * One scanned file, as the ordering and filtering policy needs it.
 *
 * Deliberately smaller than the host's own track type: this is the four fields
 * that are actually sorted or searched on, and passing anything more would make
 * the policy depend on things it does not use.
 *
 * [dateAddedSeconds] is the file's creation date and [dateModifiedSeconds] its
 * modification date, both from the file system. There is no better source — a tag
 * library does not record when *you* added a file to this machine, and inventing
 * a date from the folder scan would make the order a function of when the last
 * scan ran.
 */
@Serializable
data class LocalSong(
    val path: String,
    val title: String,
    val artist: String,
    val album: String,
    val durationSeconds: Double = 0.0,
    val dateAddedSeconds: Long? = null,
    val dateModifiedSeconds: Long? = null,
)

/**
 * The tracks in the order the listener asked for.
 *
 * Every order falls back to a case-insensitive title comparison, so two runs over
 * the same library always come back the same way. Without that, a library with
 * two tracks differing only in case swaps places between scans, which looks like
 * the file system losing track of something.
 *
 * A track with no date sorts *last* under a date order, not first. It has not
 * been added most recently — it has no date at all, and putting it at the top of a
 * "Date Added" list claims something the data does not say.
 */
fun List<LocalSong>.sortedForLibrary(order: LocalMusicSort): List<LocalSong> = when (order) {
    LocalMusicSort.TITLE_ASC -> sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.title })
    LocalMusicSort.TITLE_DESC -> sortedWith(
        compareByDescending<LocalSong> { it.title.lowercase() },
    )
    LocalMusicSort.DATE_ADDED -> sortedWith(
        compareByDescending<LocalSong> { it.dateAddedSeconds ?: Long.MIN_VALUE }
            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.title },
    )
    LocalMusicSort.DATE_MODIFIED -> sortedWith(
        compareByDescending<LocalSong> { it.dateModifiedSeconds ?: Long.MIN_VALUE }
            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.title },
    )
}

/**
 * Whether this track matches what the search box says.
 *
 * Live rather than submit-on-enter, because there is no network round trip behind
 * it — only a list already in memory — so narrowing on every keystroke costs
 * nothing and a submit action would be a tap this screen does not otherwise need.
 *
 * Every field is searched, because people look for a track by whichever of the
 * three they happen to remember. Blank means no filter rather than no results:
 * an empty box showing nothing is indistinguishable from an empty library.
 */
fun LocalSong.matchesSearch(query: String): Boolean {
    val needle = query.trim()
    if (needle.isEmpty()) return true
    return title.contains(needle, ignoreCase = true) ||
        artist.contains(needle, ignoreCase = true) ||
        album.contains(needle, ignoreCase = true)
}

/**
 * Narrow then order.
 *
 * Filtered first, then sorted, rather than the other way round — sorting a whole
 * library to show twelve rows is work thrown away, and on a large scan it is work
 * large enough to be felt.
 */
fun List<LocalSong>.libraryView(order: LocalMusicSort, query: String): List<LocalSong> =
    filter { it.matchesSearch(query) }.sortedForLibrary(order)

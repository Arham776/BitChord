package com.music.bitchord.data.model

import kotlinx.serialization.Serializable

/**
 * Port of upstream `data/model/Models.kt` — the subset of the model surface
 * the Apple app consumes. Field semantics are upstream's verbatim; Android
 * persistence annotations (none were present) would be the only thing to strip.
 */

/** A playable YouTube Music track. */
@Serializable
data class Song(
    val videoId: String,
    val title: String,
    val artist: String,
    val thumbnailUrl: String? = null,
    val durationText: String? = null,
    val artistId: String? = null,
    val albumId: String? = null,
    val albumName: String? = null,
    val isVideo: Boolean = false,
    val setVideoId: String? = null,
    val fromAutoplay: Boolean = false,
    /**
     * Clean or uncensored edition, or null when the originating catalogue did not
     * say.
     *
     * Tri-state rather than a `Boolean = false`, and that is the whole point:
     * "not stated" and "stated as clean" are different claims, and
     * [com.music.bitchord.data.sources.TrackMatcher] has to treat them differently
     * — a source that has made no claim must not be rejected for it, while two
     * sources that both stated it and disagree are describing different masters.
     * Defaulting to `false` would make every silent source look like it had
     * declared itself clean.
     */
    val isExplicit: Boolean? = null,
    /** File path for local device tracks (Apple: a plain path or bookmark-resolved URL). */
    val localPath: String? = null,
    val sourceQuality: String? = null,
)

/**
 * Artwork at a given pixel size — YouTube serves every size from one URL via
 * a `w<n>-h<n>` hint. Video thumbnails carry no hint and are returned unchanged.
 */
fun Song.artworkAt(px: Int): String? = thumbnailUrl.artworkAt(px)

/** [Song.durationText] in milliseconds, or 0 when the row didn't state one. */
fun Song.durationMillis(): Long = durationText.durationMillis()

/** As [Song.durationMillis], for a `M:SS` or `H:MM:SS` string on its own. */
fun String?.durationMillis(): Long {
    val parts = this?.trim()?.takeIf { it.isNotEmpty() }?.split(":") ?: return 0L
    val numbers = parts.map { it.trim().toLongOrNull() ?: return 0L }
    val seconds = when (numbers.size) {
        2 -> numbers[0] * 60 + numbers[1]
        3 -> numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
        else -> return 0L
    }
    return (seconds * 1_000).coerceAtLeast(0L)
}

/** As [Song.artworkAt], for artwork that isn't a track's. */
fun String?.artworkAt(px: Int): String? = this?.replace(SIZE_HINT, "w$px-h$px")

private val SIZE_HINT = Regex("""w\d+-h\d+""")

/** Artwork for a list row — one value for every row so they share a cache entry. */
const val ROW_ART_PX = 160

/** Artwork for a shelf card. */
const val CARD_ART_PX = 480

/** Artwork for a page header, drawn near enough full width. */
const val HEADER_ART_PX = 720

/** Artwork handed to the media session / widget — one generous copy. */
const val NOTIFICATION_ART_PX = 544

enum class BrowseType { ALBUM, ARTIST, PLAYLIST, OTHER }

/** YouTube Music browse ids are prefixed by kind. */
fun browseTypeOf(browseId: String, fallback: BrowseType = BrowseType.OTHER): BrowseType = when {
    browseId.startsWith("UC") -> BrowseType.ARTIST
    browseId.startsWith("MPREb") || browseId.startsWith("OLAK") -> BrowseType.ALBUM
    browseId.startsWith("VL") || browseId.startsWith("PL") -> BrowseType.PLAYLIST
    else -> fallback
}

/** A non-track search result: album, artist or playlist. */
@Serializable
data class BrowseItem(
    val browseId: String,
    val title: String,
    val subtitle: String,
    val thumbnailUrl: String?,
    val type: BrowseType,
)

/**
 * Search rows are heterogeneous once filters other than "Songs" are used.
 *
 * [TopTrack] is not a better-ranked track — it is *the* track YouTube Music
 * itself promoted, read from the card at the head of an unfiltered search. Taking
 * Google's own choice rather than scoring the results ourselves is the difference
 * between showing the answer and showing our guess at one, and it is why this is a
 * distinct case rather than a flag on [Track]: a promoted card can legitimately be
 * a track with no place in the list at all, and a row that merely happened to sort
 * well is not a promotion.
 */
@Serializable
sealed interface SearchResult {
    @Serializable
    data class TopTrack(val song: Song) : SearchResult

    @Serializable
    data class Track(val song: Song) : SearchResult

    @Serializable
    data class Browse(val item: BrowseItem) : SearchResult
}

enum class SearchFilter(val label: String, val params: String?) {
    /**
     * YouTube Music's mixed search page: songs, artists, albums and playlists.
     *
     * The only filter that carries a promoted card, and so the only one a top
     * result is shown for — a "Songs" search is already entirely songs, and a
     * heading above a list of the same rows adds nothing.
     */
    ALL("All", null),
    SONGS("Songs", "EgWKAQIIAWoKEAkQChAFEAMQBA=="),
    VIDEOS("Videos", "EgWKAQIQAWoKEAkQChAFEAMQBA=="),
    ALBUMS("Albums", "EgWKAQIYAWoKEAkQChAFEAMQBA=="),
    ARTISTS("Artists", "EgWKAQIgAWoKEAkQChAFEAMQBA=="),
    PLAYLISTS("Playlists", "EgWKAQIoAWoKEAkQChAFEAMQBA=="),
}

/** A card in a home-feed carousel: either a track (videoId) or an album/playlist (browseId). */
@Serializable
data class ShelfItem(
    val title: String,
    val subtitle: String,
    val thumbnailUrl: String?,
    val videoId: String? = null,
    val browseId: String? = null,
)

@Serializable
data class HomeShelf(
    val title: String,
    val items: List<ShelfItem>,
    val subtitle: String = "",
)

/** A page of the Home feed, plus the token for the next one — null once exhausted. */
@Serializable
data class HomeFeed(
    val shelves: List<HomeShelf>,
    val continuation: String? = null,
)

/** A browsed album / artist / playlist page. */
@Serializable
data class DetailPage(
    val browseId: String,
    val title: String,
    val subtitle: String,
    val thumbnailUrl: String?,
    val songs: List<Song>,
    val type: BrowseType = BrowseType.OTHER,
    val sections: List<HomeShelf> = emptyList(),
    val description: String? = null,
    val subscriberCountText: String? = null,
    val monthlyListenerCount: String? = null,
    /** Token for the rest of the track list — null once it is all in. */
    val continuation: String? = null,
    val suggestedSongs: List<Song> = emptyList(),
    val libraryPlaylistId: String? = null,
    val librarySaved: Boolean? = null,
    val playlistOwned: Boolean? = null,
)

/** The next page of a paged track list (a big playlist's continuation). */
@Serializable
data class SongBatch(
    val songs: List<Song>,
    val continuation: String? = null,
)

/**
 * One resolved stream URL for a videoId. The Rust engine's streaming reader
 * fetches [url] with ranged GETs; [kbps] and [mimeType] describe what it is.
 */
@Serializable
data class ResolvedStream(
    val url: String,
    val kbps: Int,
    val mimeType: String,
)

/** The signed-in account, off YouTube's `account_menu`. */
@Serializable
data class Account(
    val name: String,
    val email: String,
    val photoUrl: String? = null,
)

/**
 * Whether an album or playlist is in the library, and the id that changes that.
 * YouTube likes the playlist behind the page, not the browse id.
 */
@Serializable
data class LibraryState(
    val playlistId: String,
    val saved: Boolean,
)

enum class LikeStatus { LIKE, DISLIKE, INDIFFERENT }

/** Who can see a playlist. YouTube's own three values, sent verbatim. */
enum class PlaylistPrivacy(val label: String, val apiValue: String) {
    PRIVATE("Private", "PRIVATE"),
    UNLISTED("Unlisted", "UNLISTED"),
    PUBLIC("Public", "PUBLIC"),
}

/** One of the account's own playlists, as the picker lists them. */
@Serializable
data class UserPlaylist(
    val playlistId: String,
    val title: String,
    val subtitle: String,
    val thumbnailUrl: String?,
) {
    val browseId: String get() = "VL$playlistId"
}

/** Per-track rating and library tokens from the watch-queue menu. */
@Serializable
data class SongMenu(
    val likeStatus: String? = null,
    val inLibrary: Boolean = false,
    val addToLibraryToken: String? = null,
    val removeFromLibraryToken: String? = null,
)

/** A search row that Swift can decode without sealed-class discriminators. */
@Serializable
data class SearchHit(
    val kind: String,
    val videoId: String? = null,
    val title: String,
    val subtitle: String = "",
    val thumbnailUrl: String? = null,
    val durationText: String? = null,
    val albumName: String? = null,
    val browseId: String? = null,
    val browseType: String? = null,
    val artistId: String? = null,
    val albumId: String? = null,
    val isVideo: Boolean = false,
    val setVideoId: String? = null,
)

sealed interface UiState<out T> {
    data object Loading : UiState<Nothing>
    data class Success<T>(val data: T) : UiState<T>
    data class Error(val message: String) : UiState<Nothing>
}

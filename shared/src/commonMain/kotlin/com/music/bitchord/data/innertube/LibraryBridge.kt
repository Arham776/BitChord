package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.HomeFeed
import com.music.bitchord.data.model.HomeShelf
import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Signed-in library shelves — playlists, albums, artists — matching upstream
 * `LibraryScreen`. Track lists are not drawn as card rows: a run of songs
 * from one album becomes a row of identical sleeves.
 */
object LibraryBridge {

    private const val LIBRARY_SONGS = "FEmusic_liked_videos"

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    private val FEEDS = listOf(
        "Playlists" to "FEmusic_liked_playlists",
        "Albums" to "FEmusic_liked_albums",
        "Artists" to "FEmusic_library_corpus_track_artists",
        "Subscriptions" to "FEmusic_library_corpus_artists",
        "Podcasts" to "FEmusic_library_non_music_audio_list",
    )

    fun interface FeedCallback {
        fun onResult(json: String?, message: String?)
    }

    /**
     * Songs explicitly added to the library (`FEmusic_liked_videos`) —
     * distinct from Liked Music, which is a rating, not membership. Same
     * `[Song]` JSON contract as the history bridge, decoded Apple-side into
     * `[YouTubeSong]`.
     */
    fun librarySongs(callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) {
                    callback.onResult(
                        json.encodeToString(ListSerializer(Song.serializer()), emptyList()),
                        null,
                    )
                    return@launch
                }
                val songs = InnertubeParser.collectSongsDeep(Innertube.browse(LIBRARY_SONGS))
                    .distinctBy { it.videoId }
                callback.onResult(json.encodeToString(ListSerializer(Song.serializer()), songs), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun library(callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) {
                    callback.onResult(
                        json.encodeToString(HomeFeed.serializer(), HomeFeed(emptyList())),
                        null,
                    )
                    return@launch
                }
                val shelves = coroutineScope {
                    FEEDS.map { (title, browseId) ->
                        async {
                            val items = runCatching {
                                InnertubeParser.parseLibraryItems(Innertube.browse(browseId))
                            }.getOrDefault(emptyList())
                            HomeShelf(title, items)
                        }
                    }.awaitAll().filter { it.items.isNotEmpty() }
                }
                callback.onResult(
                    json.encodeToString(HomeFeed.serializer(), HomeFeed(shelves)),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}

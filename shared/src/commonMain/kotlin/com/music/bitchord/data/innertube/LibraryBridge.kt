package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.HomeFeed
import com.music.bitchord.data.model.HomeShelf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Signed-in library shelves — playlists, albums, artists — matching upstream
 * `LibraryScreen`. Track lists are not drawn as card rows: a run of songs
 * from one album becomes a row of identical sleeves.
 */
object LibraryBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    private val FEEDS = listOf(
        "Playlists" to "FEmusic_liked_playlists",
        "Albums" to "FEmusic_liked_albums",
        "Artists" to "FEmusic_library_corpus_track_artists",
        "Subscriptions" to "FEmusic_library_corpus_artists",
    )

    fun interface FeedCallback {
        fun onResult(json: String?, message: String?)
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

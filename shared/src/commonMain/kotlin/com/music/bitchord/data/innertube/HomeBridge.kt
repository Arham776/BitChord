package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog

import com.music.bitchord.data.model.HomeFeed
import com.music.bitchord.data.model.HomeShelf
import com.music.bitchord.data.model.ShelfItem
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
 * Home / Explore / history, matching upstream `YtMusicRepository`:
 * Home = recently played (signed-in) + FEmusic_home + FEmusic_new_releases,
 * plus FEmusic_home's continuation for signed-in paging.
 */
object HomeBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    private const val HISTORY = "FEmusic_history"
    private const val RECENT_TITLE = "Recently played"
    private const val RECENT_LIMIT = 20

    fun interface FeedCallback {
        fun onResult(json: String?, message: String?)
    }

    fun home(callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) Innertube.ensureVisitorData()
                val feed = coroutineScope {
                    val recent = async { runCatching { recentlyPlayed() }.getOrNull() }
                    val homeRaw = async { Innertube.browse("FEmusic_home") }
                    val newReleases = async {
                        runCatching { InnertubeParser.parseHome(Innertube.browse("FEmusic_new_releases")) }
                            .getOrDefault(emptyList())
                    }
                    val home = homeRaw.await()
                    val shelves = listOfNotNull(recent.await()) +
                        InnertubeParser.parseHome(home) +
                        newReleases.await()
                    HomeFeed(
                        shelves = shelves.distinctBy { it.title.lowercase() },
                        continuation = InnertubeParser.continuationToken(home),
                    )
                }
                check(feed.shelves.isNotEmpty()) { "No results from YouTube Music" }
                DebugLog.d(
                    "home: signedIn=${Innertube.cookie != null} " +
                        "shelves=${feed.shelves.size} " +
                        "titles=${feed.shelves.joinToString { it.title }}",
                )
                callback.onResult(json.encodeToString(HomeFeed.serializer(), feed), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun moreHome(token: String, callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                val response = Innertube.browseContinuation(token)
                val feed = HomeFeed(
                    shelves = InnertubeParser.parseHomeContinuation(response),
                    continuation = InnertubeParser.continuationToken(response),
                )
                callback.onResult(json.encodeToString(HomeFeed.serializer(), feed), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun explore(callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) Innertube.ensureVisitorData()
                val explore = Innertube.browse("FEmusic_explore")
                val charts = runCatching { InnertubeParser.parseHome(Innertube.browse("FEmusic_charts")) }
                    .getOrDefault(emptyList())
                val shelves = (InnertubeParser.parseHome(explore) + charts)
                    .distinctBy { it.title.lowercase() }
                check(shelves.isNotEmpty()) { "No results from YouTube Music" }
                callback.onResult(
                    json.encodeToString(
                        HomeFeed.serializer(),
                        HomeFeed(shelves, InnertubeParser.continuationToken(explore)),
                    ),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun moreExplore(token: String, callback: FeedCallback) {
        moreHome(token, callback)
    }

    fun history(callback: FeedCallback) {
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
                val songs = fetchHistory()
                callback.onResult(json.encodeToString(ListSerializer(Song.serializer()), songs), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    private fun feed(browseIds: List<String>, callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) Innertube.ensureVisitorData()
                val shelves = browseIds
                    .map { id ->
                        async {
                            runCatching { InnertubeParser.parseHome(Innertube.browse(id)) }
                                .getOrDefault(emptyList())
                        }
                    }
                    .awaitAll()
                    .flatten()
                    .distinctBy { it.title.lowercase() }
                check(shelves.isNotEmpty()) { "No results from YouTube Music" }
                callback.onResult(
                    json.encodeToString(HomeFeed.serializer(), HomeFeed(shelves)),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    private suspend fun recentlyPlayed(): HomeShelf? {
        if (Innertube.cookie == null) return null
        val songs = fetchHistory().take(RECENT_LIMIT)
        if (songs.isEmpty()) return null
        return HomeShelf(
            title = RECENT_TITLE,
            items = songs.map {
                ShelfItem(
                    title = it.title,
                    subtitle = it.artist,
                    thumbnailUrl = it.thumbnailUrl,
                    videoId = it.videoId,
                    browseId = null,
                )
            },
        )
    }

    private suspend fun fetchHistory(): List<Song> =
        InnertubeParser.collectSongsDeep(Innertube.browse(HISTORY)).distinctBy { it.videoId }
}

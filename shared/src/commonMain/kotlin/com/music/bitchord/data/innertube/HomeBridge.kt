package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog

import com.music.bitchord.data.model.HomeFeed
import com.music.bitchord.data.model.HomeShelf
import com.music.bitchord.data.model.MoodGenreSection
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

    fun interface MoodCallback {
        fun onResult(json: String?, message: String?)
    }

    fun interface ArtworkCallback {
        fun onResult(url: String?, message: String?)
    }

    /**
     * Category shelves, kept so a category's cover and its contents are one
     * request rather than two. A plain map rather than a flow because the
     * [MoodCallback] answer is already the UI's to publish.
     */
    private val moodGenreShelfCache = mutableMapOf<String, List<HomeShelf>>()

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

    /**
     * The server-defined mood and genre categories behind Explore.
     *
     * Separate from [explore] because it is a different browse response with a
     * different shape: shelves the app chose to show, versus categories YouTube
     * itself defines. Explore paints the shelves and the categories, so both are
     * needed, and neither can be derived from the other.
     */
    fun moodAndGenres(callback: MoodCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) Innertube.ensureVisitorData()
                val sections = InnertubeParser.parseMoodAndGenres(
                    Innertube.browse("FEmusic_moods_and_genres")
                )
                check(sections.isNotEmpty()) { "No mood or genre categories" }
                callback.onResult(
                    json.encodeToString(
                        ListSerializer(MoodGenreSection.serializer()), sections
                    ),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    /**
     * The playlist shelves behind one mood/genre category.
     *
     * Cached because the same response supplies the category's tile artwork, so
     * without the cache a listener who taps a category whose cover has already
     * appeared waits for the same bytes twice. Keyed by browse id *and* params:
     * two categories can share an id and differ only by params, and collapsing
     * them would show one category's playlists under another's name.
     */
    fun moodGenreShelves(browseId: String, params: String?, callback: FeedCallback) {
        val key = "$browseId:${params.orEmpty()}"
        moodGenreShelfCache[key]?.let { cached ->
            callback.onResult(
                json.encodeToString(HomeFeed.serializer(), HomeFeed(cached)),
                null,
            )
            return
        }
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                val shelves = InnertubeParser.parseHome(Innertube.browse(browseId, params))
                moodGenreShelfCache[key] = shelves
                callback.onResult(
                    json.encodeToString(HomeFeed.serializer(), HomeFeed(shelves)),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    /**
     * A category's tile artwork: the first real cover from the playlists it
     * opens.
     *
     * "Real" is doing work here — a category with no cover of its own borrows
     * one from its contents rather than shipping an empty tile, which is why
     * this reuses the shelf cache instead of asking for the covers separately.
     */
    fun moodGenreArtwork(browseId: String, params: String?, callback: ArtworkCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                val shelves = moodGenreShelfCache["$browseId:${params.orEmpty()}"]
                    ?: InnertubeParser.parseHome(Innertube.browse(browseId, params))
                        .also { moodGenreShelfCache["$browseId:${params.orEmpty()}"] = it }
                val cover = shelves.asSequence()
                    .flatMap { it.items.asSequence() }
                    .mapNotNull { it.thumbnailUrl }
                    .firstOrNull { it.isNotBlank() }
                callback.onResult(cover, null)
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

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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.concurrent.atomics.AtomicLong
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Home / Explore / history, matching upstream `YtMusicRepository`:
 * Home = recently played (signed-in) + FEmusic_home + the upstream
 * FEmusic_new_releases and FEmusic_explore supplements, plus FEmusic_home's
 * continuation for signed-in paging.
 */
@OptIn(ExperimentalAtomicApi::class)
object HomeBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    private const val HISTORY = "FEmusic_history"
    private const val RECENT_TITLE = "Recents"
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
     * request rather than two. Only identical active requests share a flight;
     * the app-owned page repository controls freshness and disk persistence.
     */
    private val moodLock = Mutex()
    private val moodGenreFlights = mutableMapOf<String, Deferred<List<HomeShelf>>>()
    private val requestIds = AtomicLong(0)
    private val requests = AtomicReference<Map<Long, Job>>(emptyMap())
    private fun updateRequests(change: (Map<Long, Job>) -> Map<Long, Job>) {
        while (true) {
            val old = requests.load()
            if (requests.compareAndSet(old, change(old))) return
        }
    }
    fun interface ProgressiveCallback {
        fun onResult(json: String?, complete: Boolean, message: String?)
    }
    fun cancelFeed(requestId: Long) { requests.load()[requestId]?.cancel() }
    fun homeProgressive(callback: ProgressiveCallback): Long = startFeed(true, callback)
    fun exploreProgressive(callback: ProgressiveCallback): Long = startFeed(false, callback)

    private fun startFeed(home: Boolean, callback: ProgressiveCallback): Long {
        val id = requestIds.fetchAndAdd(1) + 1
        val generation = Innertube.sessionGeneration
        val job = bridgeScope.launch(start = CoroutineStart.LAZY) {
            try {
                Innertube.ensureSessionScope()
                if (Innertube.cookie == null) Innertube.ensureVisitorData()
                Innertube.checkSession(generation)
                progressiveFeed(home, generation, publish = { feed, complete ->
                    callback.onResult(json.encodeToString(HomeFeed.serializer(), feed), complete, null)
                })
            } catch (e: Throwable) {
                callback.onResult(null, true, e.message ?: "Feed unavailable")
            } finally { updateRequests { it - id } }
        }
        updateRequests { it + (id to job) }
        job.start()
        return id
    }

    internal suspend fun progressiveFeed(
        home: Boolean, generation: Long,
        publish: (HomeFeed, Boolean) -> Unit,
        browse: suspend (String) -> kotlinx.serialization.json.JsonObject = { Innertube.browse(it) },
    ) = coroutineScope {
        // Supplements are independent and never hold the primary feed off screen.
        val parts = List(if (home) 4 else 2) { emptyList<HomeShelf>() }.toMutableList()
        val extras = if (home) listOf("FEmusic_history", "FEmusic_new_releases", "FEmusic_explore")
            else listOf("FEmusic_charts")
        val completed = kotlinx.coroutines.channels.Channel<Pair<Int, List<HomeShelf>>>(extras.size)
        val extraJobs = extras.mapIndexed { index, name ->
            launch {
                val shelves = try {
                    if (name == HISTORY) {
                        if (Innertube.cookie == null) emptyList() else {
                            val songs = InnertubeParser.collectSongsDeep(browse(name)).distinctBy { it.videoId }.take(RECENT_LIMIT)
                            if (songs.isEmpty()) emptyList() else listOf(HomeShelf(RECENT_TITLE, songs.map {
                                ShelfItem(it.title, it.artist, it.thumbnailUrl, it.videoId, null)
                            }))
                        }
                    } else InnertubeParser.parseHome(browse(name))
                } catch (e: CancellationException) { throw e }
                  catch (_: Exception) { emptyList() }
                completed.send(index to shelves)
            }
        }
        try {
            val primary = browse(if (home) "FEmusic_home" else "FEmusic_explore")
            parts[if (home) 1 else 0] = InnertubeParser.parseHome(primary)
            val token = InnertubeParser.continuationToken(primary)
            fun emit(complete: Boolean) {
                Innertube.checkSession(generation)
                val shelves = parts.flatten().distinctBy { it.title.lowercase() }
                if (complete) check(shelves.isNotEmpty()) { "No results from YouTube Music" }
                publish(HomeFeed(shelves, token), complete)
            }
            emit(false)
            repeat(extras.size) { count ->
                val (index, shelves) = completed.receive()
                parts[if (home && index == 0) 0 else index + (if (home) 1 else 1)] = shelves
                // Home parts: history=0, primary=1, releases=2, explore=3.
                emit(count == extras.lastIndex)
            }
        } finally { extraJobs.forEach { it.cancel() }; completed.close() }
    }

    fun home(callback: FeedCallback) {
        homeProgressive { payload, complete, message ->
            if (complete) callback.onResult(payload, message)
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
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
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
    private suspend fun categoryShelves(browseId: String, params: String?): List<HomeShelf> {
        val generation = Innertube.sessionGeneration
        val key = "$generation:$browseId:${params.orEmpty()}"
        val flight = moodLock.withLock {
            Innertube.checkSession(generation)
            moodGenreFlights[key] ?: bridgeScope.async(start = CoroutineStart.LAZY) {
                val shelves = InnertubeParser.parseHome(Innertube.browse(browseId, params))
                Innertube.checkSession(generation)
                shelves
            }.also { moodGenreFlights[key] = it; it.start() }
        }
        try { return flight.await().also { Innertube.checkSession(generation) } }
        finally {
            moodLock.withLock {
                if (moodGenreFlights[key] === flight && flight.isCompleted) moodGenreFlights.remove(key)
            }
        }
    }

    fun moodGenreShelves(browseId: String, params: String?, callback: FeedCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val shelves = categoryShelves(browseId, params)
                callback.onResult(json.encodeToString(HomeFeed.serializer(), HomeFeed(shelves)), null)
            } catch (e: Throwable) { callback.onResult(null, e.message ?: "Category unavailable") }
        }
    }
    fun moodGenreArtwork(browseId: String, params: String?, callback: ArtworkCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val cover = categoryShelves(browseId, params).asSequence().flatMap { it.items.asSequence() }
                    .mapNotNull { it.thumbnailUrl }.firstOrNull { it.isNotBlank() }
                callback.onResult(cover, null)
            } catch (e: Throwable) { callback.onResult(null, e.message ?: "Artwork unavailable") }
        }
    }

    fun moreHome(token: String, callback: FeedCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
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
        exploreProgressive { payload, complete, message ->
            if (complete) callback.onResult(payload, message)
        }
    }

    fun moreExplore(token: String, callback: FeedCallback) {
        moreHome(token, callback)
    }

    fun history(callback: FeedCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
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
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
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

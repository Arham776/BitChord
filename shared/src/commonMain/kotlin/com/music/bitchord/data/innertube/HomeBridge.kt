package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.HomeFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Swift-facing bridge for the signed-out Home and Explore feeds, mirroring
 * upstream's `YtMusicRepository.home()/explore()` pairing of browse pages:
 * Home = FEmusic_home + FEmusic_new_releases (the first page alone is thin
 * signed out), Explore = FEmusic_explore + FEmusic_charts de-duped by title.
 * Both work as a guest. The feed crosses as JSON, same contract as
 * [SearchBridge].
 */
object HomeBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface FeedCallback {
        /** Called on a background thread with either [json] or [message]. */
        fun onResult(json: String?, message: String?)
    }

    fun home(callback: FeedCallback) {
        feed(listOf("FEmusic_home", "FEmusic_new_releases"), callback)
    }

    fun explore(callback: FeedCallback) {
        feed(listOf("FEmusic_explore", "FEmusic_charts"), callback)
    }

    private fun feed(browseIds: List<String>, callback: FeedCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
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
}

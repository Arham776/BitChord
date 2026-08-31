package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.SearchHit
import com.music.bitchord.data.model.SearchResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Swift-facing coroutine bridge over the suspend innertube API.
 * Returns mixed track/browse hits so Albums / Artists / Playlists scopes work.
 */
object SearchBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun interface SearchCallback {
        fun onResult(json: String?, message: String?)
    }

    fun search(query: String, scope: String, callback: SearchCallback) {
        bridgeScope.launch {
            try {
                val response = Innertube.search(query, InnertubeParser.paramsFor(scope))
                val hits = InnertubeParser.parseSearch(response).map { result ->
                    when (result) {
                        is SearchResult.Track -> SearchHit(
                            kind = "track",
                            videoId = result.song.videoId,
                            title = result.song.title,
                            subtitle = result.song.artist,
                            thumbnailUrl = result.song.thumbnailUrl,
                            durationText = result.song.durationText,
                            albumName = result.song.albumName,
                            artistId = result.song.artistId,
                            albumId = result.song.albumId,
                            isVideo = result.song.isVideo,
                            setVideoId = result.song.setVideoId,
                        )
                        is SearchResult.Browse -> SearchHit(
                            kind = "browse",
                            title = result.item.title,
                            subtitle = result.item.subtitle,
                            thumbnailUrl = result.item.thumbnailUrl,
                            browseId = result.item.browseId,
                            browseType = result.item.type.name,
                        )
                    }
                }
                callback.onResult(json.encodeToString(ListSerializer(SearchHit.serializer()), hits), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}

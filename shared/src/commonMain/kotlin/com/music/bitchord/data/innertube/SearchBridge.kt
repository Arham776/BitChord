package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.SearchHit
import com.music.bitchord.data.model.SearchFilter
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
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val response = Innertube.search(query, InnertubeParser.paramsFor(scope))
                // The Videos tab is the one filter whose results are not music, so
                // the promoted card is not read there at all.
                val includeVideos = scope == SearchFilter.VIDEOS.name
                val hits = InnertubeParser.parseSearchPage(response, includeVideos)
                    .map { result -> hitOf(result) }
                Innertube.checkSession(generation)
                callback.onResult(json.encodeToString(ListSerializer(SearchHit.serializer()), hits), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    /**
     * The promoted card and an ordinary track are the same row on screen; what
     * differs is the heading above them, and the host tells them apart by [kind].
     */
    private fun hitOf(result: SearchResult): SearchHit = when (result) {
        is SearchResult.TopTrack -> trackHit(result.song, kind = "top")
        is SearchResult.Track -> trackHit(result.song, kind = "track")
        is SearchResult.Browse -> SearchHit(
            kind = "browse",
            title = result.item.title,
            subtitle = result.item.subtitle,
            thumbnailUrl = result.item.thumbnailUrl,
            browseId = result.item.browseId,
            browseType = result.item.type.name,
        )
    }

    private fun trackHit(song: com.music.bitchord.data.model.Song, kind: String) = SearchHit(
        kind = kind,
        videoId = song.videoId,
        title = song.title,
        subtitle = song.artist,
        thumbnailUrl = song.thumbnailUrl,
        durationText = song.durationText,
        albumName = song.albumName,
        artistId = song.artistId,
        albumId = song.albumId,
        isVideo = song.isVideo,
        setVideoId = song.setVideoId,
    )

}

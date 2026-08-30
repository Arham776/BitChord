package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.DetailPage
import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Swift-facing bridge for browsing detail pages (albums, artists, playlists).
 * Returns the page as serialized JSON. The Swift side decodes into its own
 * model types.
 */
object DetailBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface DetailCallback {
        fun onResult(json: String?, message: String?)
    }

    fun browse(browseId: String, callback: DetailCallback) {
        bridgeScope.launch {
            try {
                val response = Innertube.browse(browseId)
                val header = InnertubeParser.parseBrowseHeader(response)
                val songs = InnertubeParser.collectSongsDeep(response)
                val description = InnertubeParser.parseDescription(response)
                val playlistShelf = InnertubeParser.parsePlaylistShelf(response)

                val page = DetailPage(
                    browseId = browseId,
                    title = header?.title ?: "",
                    subtitle = header?.subtitle ?: "",
                    thumbnailUrl = header?.thumbnailUrl,
                    songs = playlistShelf?.songs ?: songs,
                    sections = emptyList(),
                    description = description,
                    continuation = playlistShelf?.continuation
                        ?: InnertubeParser.continuationToken(response),
                )
                callback.onResult(
                    json.encodeToString(DetailPage.serializer(), page),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    fun browseArtist(browseId: String, callback: DetailCallback) {
        bridgeScope.launch {
            try {
                val response = Innertube.browse(browseId)
                val artistPage = InnertubeParser.parseArtistPage(response)
                val page = DetailPage(
                    browseId = browseId,
                    title = artistPage.name ?: "",
                    subtitle = artistPage.subscriberCountText ?: "",
                    thumbnailUrl = artistPage.thumbnailUrl,
                    songs = artistPage.songs,
                    sections = artistPage.sections,
                    description = artistPage.description,
                    monthlyListenerCount = artistPage.monthlyListenerCount,
                )
                callback.onResult(
                    json.encodeToString(DetailPage.serializer(), page),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}

package com.music.bitchord.data.canvas

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

object CanvasBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { encodeDefaults = true }
    private val lock = Mutex()

    fun interface CanvasCallback {
        fun onResult(json: String?)
    }

    fun lookup(title: String, artist: String, album: String?, callback: CanvasCallback) {
        scope.launch {
            val art = runCatching {
                val cleanTitle = title.cleanedForCanvas()
                val cleanArtist = artist.cleanedForCanvas()
                if (cleanTitle.isBlank() || cleanArtist.isBlank()) return@runCatching null
                lock.withLock {
                    firstHit(
                        { AppleMusicCanvas.search(cleanTitle, cleanArtist, album) },
                        { TidalCanvas.search(cleanTitle, cleanArtist, album) },
                        { CommunityCanvas.search(cleanTitle, cleanArtist, album) },
                        { SpotifyCanvas.search(cleanTitle, cleanArtist, album) },
                    ) { it.matches(cleanTitle, cleanArtist, album) }
                }
            }.getOrNull()
            callback.onResult(art?.encode())
        }
    }

    /**
     * Album-page canvas: ask each catalogue for the release itself (Spotify last).
     * A separate lookup rather than the first track's.
     */
    fun lookupAlbum(album: String, artist: String, callback: CanvasCallback) {
        scope.launch {
            val art = runCatching {
                val name = album.cleanedForCanvas()
                val credit = artist.cleanedForCanvas()
                if (name.isBlank() || credit.isBlank()) return@runCatching null
                lock.withLock {
                    firstHit(
                        { AppleMusicCanvas.searchAlbum(name, credit) },
                        { TidalCanvas.searchAlbum(name, credit) },
                        { CommunityCanvas.searchAlbum(name, credit) },
                        { SpotifyCanvas.searchAlbum(name, credit) },
                    ) { it.matches(name, credit, name) }
                }
            }.getOrNull()
            callback.onResult(art?.encode())
        }
    }

    private fun CanvasArtworkDto.encode(): String? =
        json.encodeToString(Payload.serializer(), Payload(url, source, fallbackUrl))

    private suspend fun firstHit(
        vararg sources: suspend () -> CanvasArtworkDto?,
        accept: (CanvasArtworkDto) -> Boolean,
    ): CanvasArtworkDto? {
        for (source in sources) {
            val found = runCatching { source() }.getOrNull() ?: continue
            if (!accept(found)) continue
            return found
        }
        return null
    }

    @Serializable
    private data class Payload(
        val url: String,
        val source: String,
        val fallbackUrl: String? = null,
    )
}

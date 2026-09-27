package com.music.bitchord.data.canvas

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import com.music.bitchord.data.settings.AppSettings

object CanvasBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { encodeDefaults = true }
    private val lock = Mutex()
    private const val CACHE_SIZE = 64
    private class Entry(val artwork: CanvasArtworkDto?, val withAlbum: Boolean)
    // Access is protected by [lock], including across provider resolution.
    private val cache = LinkedHashMap<String, Entry>(CACHE_SIZE, 0.75f, true)

    fun interface CanvasCallback {
        fun onResult(json: String?)
    }

    fun lookup(title: String, artist: String, album: String?, callback: CanvasCallback) {
        scope.launch {
            val art = runCatching {
                val cleanTitle = title.cleanedForCanvas()
                val cleanArtist = artist.cleanedForCanvas()
                if (cleanTitle.isBlank() || cleanArtist.isBlank()) return@runCatching null
                val cleanAlbum = album?.cleanedForCanvas()?.takeIf { it.isNotBlank() }
                val spotifyFirst = AppSettings.prioritizeSpotifyCanvas.value
                val key = "song|${cleanTitle.lowercase()}|${cleanArtist.lowercase()}|spotifyFirst=$spotifyFirst"
                resolve(key, cleanAlbum != null) {
                    if (spotifyFirst) firstHit(
                        { SpotifyCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { AppleMusicCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { TidalCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { CommunityCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                    ) { it.matches(cleanTitle, cleanArtist, cleanAlbum) }
                    else firstHit(
                        { AppleMusicCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { TidalCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { CommunityCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                        { SpotifyCanvas.search(cleanTitle, cleanArtist, cleanAlbum) },
                    ) { it.matches(cleanTitle, cleanArtist, cleanAlbum) }
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
                val spotifyFirst = AppSettings.prioritizeSpotifyCanvas.value
                val key = "album|${name.lowercase()}|${credit.lowercase()}|spotifyFirst=$spotifyFirst"
                resolve(key, withAlbum = true) {
                    if (spotifyFirst) firstHit(
                        { SpotifyCanvas.searchAlbum(name, credit) },
                        { AppleMusicCanvas.searchAlbum(name, credit) },
                        { TidalCanvas.searchAlbum(name, credit) },
                        { CommunityCanvas.searchAlbum(name, credit) },
                    ) { it.matches(name, credit, name) }
                    else firstHit(
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

    private suspend fun resolve(
        key: String,
        withAlbum: Boolean,
        lookUp: suspend () -> CanvasArtworkDto?,
    ): CanvasArtworkDto? = lock.withLock {
        cache[key]?.let { if (it.artwork != null || it.withAlbum || !withAlbum) return@withLock it.artwork }
        val found = lookUp()
        cache[key] = Entry(found, withAlbum)
        if (cache.size > CACHE_SIZE) cache.entries.iterator().run { next(); remove() }
        found
    }

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

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
                    ) { it.matches(cleanTitle, cleanArtist, album) }
                }
            }.getOrNull()
            callback.onResult(
                art?.let {
                    json.encodeToString(
                        Payload.serializer(),
                        Payload(it.url, it.source, it.fallbackUrl),
                    )
                },
            )
        }
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

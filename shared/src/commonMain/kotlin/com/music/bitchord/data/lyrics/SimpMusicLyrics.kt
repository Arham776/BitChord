package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.abs

/**
 * Port of upstream `SimpMusicLyrics` — keyed on YouTube video id.
 */
object SimpMusicLyrics {

    private const val BASE = "https://api-lyrics.simpmusic.org/v1/"
    private const val DURATION_TOLERANCE_SECONDS = 10
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun lyrics(videoId: String, durationMs: Long): List<LyricLineDto>? {
        if (videoId.isBlank()) return null
        val body = runCatching { Http.getText(BASE + videoId, timeoutMillis = 8_000) }.getOrNull()
            ?: return null
        val response = runCatching { json.decodeFromString(Response.serializer(), body) }.getOrNull()
            ?: return null
        if (!response.success) return null
        val seconds = (durationMs / 1000).toInt()
        val track = response.data.orEmpty()
            .filter { seconds <= 0 || abs((it.duration ?: 0) - seconds) <= DURATION_TOLERANCE_SECONDS }
            .minByOrNull { abs((it.duration ?: 0) - seconds) }
            ?: return null
        return track.richSyncLyrics?.takeIf { it.isNotBlank() }
            ?.let { EnhancedLrc.parse(it) }
            ?.takeIf { it.isNotEmpty() }
            ?: track.syncedLyrics?.takeIf { it.isNotBlank() }
                ?.let { LrcLib.parseLrc(it) }
                ?.takeIf { it.isNotEmpty() }
    }

    @Serializable
    private data class Response(
        val success: Boolean = false,
        val data: List<Track>? = null,
    )

    @Serializable
    private data class Track(
        val duration: Int? = null,
        val richSyncLyrics: String? = null,
        val syncedLyrics: String? = null,
    )
}

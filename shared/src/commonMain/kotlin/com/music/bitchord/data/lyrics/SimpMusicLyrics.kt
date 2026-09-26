package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.SerialName
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
        return parse(body, durationMs)
    }

    /**
     * The tracks in [body] as lines, choosing the cut nearest [durationMs].
     *
     * Split from the fetch so the payload can be tested as a payload. It is the
     * payload that goes wrong: this provider names its fields the way nothing else
     * here does, and it renamed one of them without saying so — see [Track].
     */
    internal fun parse(body: String, durationMs: Long): List<LyricLineDto>? {
        val response = runCatching { json.decodeFromString(Response.serializer(), body) }.getOrNull()
        ?: return null
        if (!response.success) return null
        val seconds = (durationMs / 1000).toInt()
        val track = response.data.orEmpty()
            .filter { candidate -> seconds <= 0 || abs(candidate.seconds() - seconds) <= DURATION_TOLERANCE_SECONDS }
            .minByOrNull { abs(it.seconds() - seconds) }
            ?: return null
        // Word timing first, then line timing, then words with no timing at all. The
        // last is a real answer: the panel reads an unstamped lyric as words to be
        // scrolled by hand, which is what every unsynced source here gives it.
        return track.richSyncLyrics?.takeIf { it.isNotBlank() }
            ?.let { EnhancedLrc.parse(it) }
            ?.takeIf { it.isNotEmpty() }
            ?: track.syncedLyrics?.takeIf { it.isNotBlank() }
                ?.let { LrcLib.parseLrc(it) }
                ?.takeIf { it.isNotEmpty() }
            ?: track.plainLyric?.takeIf { it.isNotBlank() }
                ?.let { plain(it) }
    }

    /** One line each, all stamped zero, as every unsynced source here states it. */
    private fun plain(text: String): List<LyricLineDto> = text.lineSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .map { LyricLineDto(timeMs = 0, text = it) }
        .toList()

    @Serializable
    private data class Response(
        val success: Boolean = false,
        val data: List<Track>? = null,
    )

    @Serializable
    private data class Track(
        /**
         * The length of the cut, which the database holds several of per video.
         *
         * Sent as `durationSeconds`. Upstream — and this port, until a live run
         * against the service said otherwise — asked for `duration`, a field the
         * payload no longer has: every entry therefore arrived with a null length,
         * fell outside the tolerance window, and this source returned nothing for
         * every track it was ever asked about. Both names are read, because
         * `duration` costs one nullable field and covers a payload still carrying it.
         */
        @SerialName("durationSeconds") val durationSeconds: Int? = null,
        @SerialName("duration") val duration: Int? = null,
        val richSyncLyrics: String? = null,
        val syncedLyrics: String? = null,
        /**
         * Words with no timing — and singular, where [richSyncLyrics] is not.
         *
         * Upstream declares this field and never reads it, having spelled it
         * `plainLyrics`; the service sends `plainLyric`. Read as the last resort
         * above rather than left as a declaration nothing reads.
         */
        @SerialName("plainLyric") val plainLyric: String? = null,
    ) {
        fun seconds(): Int = durationSeconds ?: duration ?: 0
    }
}

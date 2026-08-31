package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Word-timed TTML from BetterLyrics (no API key). */
object BetterLyrics {
    private const val BASE = "https://lyrics-api.boidu.dev/getLyrics"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun lyrics(title: String, artist: String, durationMs: Long, album: String?): List<LyricLineDto>? {
        val query = buildMap {
            put("s", title)
            put("a", artist)
            if (durationMs > 0) put("d", (durationMs / 1000).toString())
            if (!album.isNullOrBlank()) put("al", album)
        }
        val body = runCatching { Http.getText(BASE, query = query) }.getOrNull() ?: return null
        val ttml = runCatching {
            (json.parseToJsonElement(body) as? JsonObject)
                ?.get("ttml")?.jsonPrimitive?.contentOrNull
        }.getOrNull() ?: return null
        return TtmlLyrics.parse(ttml).takeIf { it.isNotEmpty() }
    }
}

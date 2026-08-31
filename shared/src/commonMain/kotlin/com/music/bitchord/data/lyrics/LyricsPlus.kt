package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Syllable-timed lyrics from LyricsPlus volunteer mirrors. */
object LyricsPlus {
    private val MIRRORS = listOf(
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app",
    )
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun lyrics(title: String, artist: String, album: String?): List<LyricLineDto>? = coroutineScope {
        val jobs = MIRRORS.map { host ->
            async {
                runCatching {
                    val url = "$host/v2/lyrics"
                    val body = withTimeoutOrNull(4_000) {
                        Http.getText(
                            url,
                            query = buildMap {
                                put("title", title)
                                put("artist", artist)
                                if (!album.isNullOrBlank()) put("album", album)
                            },
                            timeoutMillis = 4_000,
                        )
                    } ?: return@runCatching null
                    parse(body)
                }.getOrNull()
            }
        }
        jobs.firstNotNullOfOrNull { it.await()?.takeIf { lines -> lines.isNotEmpty() } }
    }

    private fun parse(body: String): List<LyricLineDto>? {
        val root = json.parseToJsonElement(body) as? JsonObject ?: return null
        val ttml = root["ttml"]?.jsonPrimitive?.contentOrNull
            ?: root["lyrics"]?.jsonPrimitive?.contentOrNull
        if (!ttml.isNullOrBlank() && ttml.contains("<p")) {
            return TtmlLyrics.parse(ttml)
        }
        val synced = root["syncedLyrics"]?.jsonPrimitive?.contentOrNull
            ?: root["lrc"]?.jsonPrimitive?.contentOrNull
        if (!synced.isNullOrBlank()) {
            return EnhancedLrc.parse(synced).ifEmpty { LrcLib.parseLrc(synced) }
        }
        val data = root["data"]?.jsonArray
        if (data != null) {
            val words = data.mapNotNull { el ->
                val o = el.jsonObject
                val text = o["text"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                val start = o["start"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()
                    ?: o["time"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()
                    ?: return@mapNotNull null
                if (text.isEmpty()) null
                else LyricWordDto((start * 1000).toLong(), (start * 1000).toLong() + 300, text)
            }
            if (words.isNotEmpty()) {
                return listOf(
                    LyricLineDto(
                        timeMs = words.first().startMs,
                        text = words.joinToString(" ") { it.text },
                        words = words,
                    ),
                )
            }
        }
        return null
    }
}

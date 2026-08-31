package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Tidal's square looping video cover, via the public embed search token.
 */
object TidalCanvas {
    private const val SEARCH = "https://api.tidal.com/v1/search"
    private const val EMBED_TOKEN = "vNVdglQOjFJJGG2U"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun search(title: String, artist: String, album: String?): CanvasArtworkDto? {
        val query = if (album.isNullOrBlank()) "$artist $title" else "$album $artist $title"
        val body = runCatching {
            Http.getText(
                SEARCH,
                headers = mapOf(
                    "X-Tidal-Token" to EMBED_TOKEN,
                    "User-Agent" to CANVAS_UA,
                ),
                query = mapOf(
                    "query" to query,
                    "limit" to "10",
                    "types" to "TRACKS",
                    "countryCode" to "US",
                ),
                timeoutMillis = 8_000,
            )
        }.getOrNull() ?: return null
        val items = runCatching {
            json.parseToJsonElement(body).jsonObject["tracks"]?.jsonObject?.get("items")?.jsonArray
        }.getOrNull() ?: return null
        for (item in items) {
            val track = item as? JsonObject ?: continue
            val trackTitle = track["title"]?.jsonPrimitive?.contentOrNull ?: continue
            val artists = track["artists"]?.jsonArray
                ?.mapNotNull { it.jsonObject["name"]?.jsonPrimitive?.contentOrNull }
                .orEmpty()
            if (!isMatch(trackTitle, artists, title, artist)) continue
            val albumObj = track["album"]?.jsonObject
            val videoCover = albumObj?.get("videoCover")?.jsonPrimitive?.contentOrNull
            if (videoCover.isNullOrBlank()) continue
            val videoUrl = coverUrl(videoCover) ?: continue
            return CanvasArtworkDto(
                url = videoUrl,
                title = trackTitle,
                artist = artists.joinToString(", ").ifBlank { null },
                album = albumObj["title"]?.jsonPrimitive?.contentOrNull,
                source = "tidal",
            )
        }
        return null
    }

    private fun isMatch(
        gotName: String,
        gotArtists: List<String>,
        wantName: String,
        wantArtist: String,
    ): Boolean {
        if (gotName.normalizeForMatch() != wantName.normalizeForMatch()) return false
        val wanted = splitArtists(wantArtist)
        val credited = gotArtists.map { it.normalizeForMatch() }.filter { it.isNotBlank() }
        if (wanted.isEmpty() || credited.isEmpty()) return false
        return wanted.all { want -> credited.any { it == want } }
    }

    internal fun coverUrl(id: String): String? {
        val parts = id.split("-")
        if (parts.size != 5) return null
        return "https://resources.tidal.com/videos/${parts.joinToString("/")}/1280x1280.mp4"
    }
}

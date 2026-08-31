package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Community-curated looping video index (upstream CommunityCanvas).
 */
object CommunityCanvas {
    private const val MANIFEST = "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    @kotlin.concurrent.Volatile private var cached: List<Entry> = emptyList()

    private data class Entry(val song: String, val artist: String, val album: String, val url: String)

    suspend fun search(title: String, artist: String, album: String?): CanvasArtworkDto? {
        val index = manifest()
        val wantTitle = title.normalize()
        val wantArtist = artist.normalize()
        val wantAlbum = album?.normalize()
        val hit = index.firstOrNull { entry ->
            val song = entry.song.normalize()
            val credited = entry.artist.normalize()
            val titleOk = song.isNotBlank() && (wantTitle.contains(song) || song.contains(wantTitle))
            val artistOk = credited.isNotBlank() && (wantArtist.contains(credited) || credited.contains(wantArtist))
            val albumOk = entry.album.isBlank() || wantAlbum.isNullOrBlank() || entry.album.normalize() == wantAlbum
            titleOk && artistOk && albumOk
        } ?: return null
        return CanvasArtworkDto(
            url = hit.url,
            title = hit.song,
            artist = hit.artist,
            source = "community",
        )
    }

    private suspend fun manifest(): List<Entry> {
        if (cached.isNotEmpty()) return cached
        val body = runCatching { Http.getText(MANIFEST, timeoutMillis = 8_000) }.getOrNull() ?: return emptyList()
        val root = json.parseToJsonElement(body)
        val array: JsonArray = when (root) {
            is JsonArray -> root
            is JsonObject -> root["canvas"]?.jsonArray ?: root["data"]?.jsonArray ?: return emptyList()
            else -> return emptyList()
        }
        cached = array.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val url = o.str("url") ?: o.str("canvas") ?: o.str("video") ?: return@mapNotNull null
            Entry(
                song = o.str("song") ?: o.str("title") ?: "",
                artist = o.str("artist") ?: "",
                album = o.str("album") ?: "",
                url = url,
            )
        }
        return cached
    }

    private fun JsonObject.str(key: String): String? =
        get(key)?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

    private fun String.normalize(): String = lowercase().replace(Regex("[^a-z0-9]+"), " ").trim()
}

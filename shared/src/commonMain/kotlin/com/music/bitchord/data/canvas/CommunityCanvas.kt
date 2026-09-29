package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Community-curated looping video index (upstream CommunityCanvas).
 */
object CommunityCanvas {
    private const val MANIFEST = "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json"
    private const val TTL_MS = 30L * 60 * 1000
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val lock = Mutex()
    private var cached: List<Entry> = emptyList()
    private var fetchedAtMs = 0L

    private data class Entry(val song: String, val artist: String, val album: String, val url: String)

    suspend fun search(title: String, artist: String, album: String?): CanvasArtworkDto? {
        val index = manifest()
        val wantAlbum = album?.normalize()
        val hit = index.firstOrNull { entry ->
            val song = entry.song.communityTitleKey()
            val requested = title.communityTitleKey()
            val creditedArtists = splitArtists(entry.artist)
            val requestedArtists = splitArtists(artist)
            val titleOk = song.isNotBlank() && song == requested
            val artistOk = creditedArtists.isNotEmpty() && requestedArtists.isNotEmpty() &&
                creditedArtists.any { it in requestedArtists }
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

    /** First clip on this release — the index is keyed by song, the loop is usually the same. */
    suspend fun searchAlbum(album: String, artist: String): CanvasArtworkDto? {
        val index = manifest()
        val wantAlbum = album.normalize()
        val wantArtist = artist.normalize()
        if (wantAlbum.isBlank()) return null
        val hit = index.firstOrNull { entry ->
            val listed = entry.album.normalize()
            val credited = entry.artist.normalize()
            listed == wantAlbum && credited.isNotBlank() &&
                (wantArtist.contains(credited) || credited.contains(wantArtist))
        } ?: return null
        return CanvasArtworkDto(
            url = hit.url,
            title = hit.album,
            artist = hit.artist,
            album = hit.album,
            source = "community",
        )
    }

    private suspend fun manifest(): List<Entry> = lock.withLock {
        val now = canvasNowMs()
        if (cached.isNotEmpty() && now - fetchedAtMs < TTL_MS) return@withLock cached

        val body = runCatching { Http.getText(MANIFEST, timeoutMillis = 8_000) }.getOrNull()
        if (body == null) {
            fetchedAtMs = now
            return@withLock cached
        }

        val parsed = runCatching {
            val root = json.parseToJsonElement(body).jsonObject
            val array: JsonArray = root["items"]?.jsonArray ?: return@runCatching emptyList()
            array.mapNotNull { el ->
                val o = el as? JsonObject ?: return@mapNotNull null
                val url = o.str("url") ?: return@mapNotNull null
                Entry(
                    song = o.str("song") ?: return@mapNotNull null,
                    artist = o.str("artist") ?: return@mapNotNull null,
                    album = o.str("album").orEmpty(),
                    url = url,
                )
            }
        }.getOrNull()

        if (!parsed.isNullOrEmpty()) cached = parsed
        fetchedAtMs = now
        cached
    }

    private fun JsonObject.str(key: String): String? =
        get(key)?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

    private fun String.normalize(): String = lowercase().replace(Regex("[^a-z0-9]+"), " ").trim()
}

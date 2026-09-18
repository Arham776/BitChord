package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * Spotify's own Canvas via protobuf over HTTP.
 */
object SpotifyCanvas {

    private const val SEARCH_URL = "https://api.spotify.com/v1/search"
    private const val ALBUM_TRACKS_URL = "https://api.spotify.com/v1/albums"
    private const val CANVAS_URL = "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"
    private const val PATHFINDER_URL = "https://api-partner.spotify.com/pathfinder/v1/query"
    private const val PATHFINDER_SEARCH_HASH =
        "bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428"
    private const val SPOTIFY_APP_UA = "Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)"

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val CANVAS_URL_REGEX = Regex("""https://[^"'\s\x00-\x1F]+\.cnvs\.mp4""")

    private data class TrackHit(val uri: String, val title: String, val artist: String, val album: String?)

    suspend fun search(title: String, artist: String, album: String?): CanvasArtworkDto? {
        val token = SpotifyToken.accessToken() ?: return null
        val hit = searchViaPathfinder(title, artist, album, token)
            ?: searchViaRest(title, artist, album, token)
            ?: return null
        val canvasUrl = fetchCanvasUrl(hit.uri, token) ?: return null
        return CanvasArtworkDto(
            url = canvasUrl,
            title = hit.title,
            artist = hit.artist,
            album = hit.album,
            source = "SPOTIFY",
        )
    }

    suspend fun searchAlbum(album: String, artist: String): CanvasArtworkDto? {
        val token = SpotifyToken.accessToken() ?: return null
        val (_, body) = canvasGetWithStatus(
            SEARCH_URL,
            authHeaders(token),
            query = mapOf("q" to "$album $artist", "type" to "album", "limit" to "10"),
        )
        if (body == null) return null
        val root = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
        val items = root["albums"]?.jsonObject?.get("items")?.jsonArray ?: return null
        for (item in items) {
            val record = item as? JsonObject ?: continue
            val recordTitle = record["name"]?.jsonPrimitive?.contentOrNull ?: continue
            val artists = record["artists"]?.jsonArray
                ?.mapNotNull { it.jsonObject["name"]?.jsonPrimitive?.contentOrNull }
                .orEmpty()
            if (!isMatch(recordTitle, artists, album, artist)) continue
            val albumId = record["id"]?.jsonPrimitive?.contentOrNull ?: continue
            val trackUri = firstTrackUri(albumId, token) ?: continue
            val canvasUrl = fetchCanvasUrl(trackUri, token) ?: continue
            return CanvasArtworkDto(
                url = canvasUrl,
                title = recordTitle,
                artist = artists.joinToString(", ").ifBlank { null },
                album = recordTitle,
                source = "SPOTIFY",
            )
        }
        return null
    }

    private suspend fun searchViaPathfinder(
        title: String,
        artist: String,
        album: String?,
        token: String,
    ): TrackHit? {
        val clientToken = SpotifyToken.clientToken() ?: return null
        val searchTerm = listOfNotNull(title, artist, album).joinToString(" ")
        val variables = buildJsonObject {
            put("searchTerm", searchTerm)
            put("offset", 0)
            put("limit", 10)
            put("numberOfTopResults", 5)
            put("includeAudiobooks", false)
            put("includePreReleases", false)
        }.toString()
        val extensions = buildJsonObject {
            putJsonObject("persistedQuery") {
                put("version", 1)
                put("sha256Hash", PATHFINDER_SEARCH_HASH)
            }
        }.toString()
        val headers = mapOf(
            "Authorization" to "Bearer $token",
            "Client-Token" to clientToken,
            "App-platform" to "WebPlayer",
            "Accept" to "application/json",
            "User-Agent" to CANVAS_UA,
        )
        val (_, body) = canvasGetWithStatus(
            PATHFINDER_URL,
            headers,
            query = mapOf(
                "operationName" to "searchTracks",
                "variables" to variables,
                "extensions" to extensions,
            ),
        )
        val root = body?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
        val firstItem = root?.get("data")?.jsonObject
            ?.get("searchV2")?.jsonObject
            ?.get("tracksV2")?.jsonObject
            ?.get("items")?.jsonArray
            ?.firstOrNull()
            ?.jsonObject?.get("item")?.jsonObject
            ?.get("data")?.jsonObject
            ?: return null
        val uri = firstItem["uri"]?.jsonPrimitive?.contentOrNull
            ?: firstItem["id"]?.jsonPrimitive?.contentOrNull?.let { "spotify:track:$it" }
            ?: return null
        return TrackHit(uri, title, artist, album)
    }

    private suspend fun searchViaRest(
        title: String,
        artist: String,
        album: String?,
        token: String,
    ): TrackHit? {
        val query = listOfNotNull(title, artist, album).joinToString(" ")
        val (_, body) = canvasGetWithStatus(
            SEARCH_URL,
            authHeaders(token),
            query = mapOf("q" to query, "type" to "track", "limit" to "10"),
        )
        val root = body?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
            ?: return null
        val items = root["tracks"]?.jsonObject?.get("items")?.jsonArray ?: return null
        for (item in items) {
            val track = item as? JsonObject ?: continue
            val trackTitle = track["name"]?.jsonPrimitive?.contentOrNull ?: continue
            val artists = track["artists"]?.jsonArray
                ?.mapNotNull { it.jsonObject["name"]?.jsonPrimitive?.contentOrNull }
                .orEmpty()
            if (!isMatch(trackTitle, artists, title, artist)) continue
            val uri = track["uri"]?.jsonPrimitive?.contentOrNull ?: continue
            val albumName = track["album"]?.jsonObject?.get("name")?.jsonPrimitive?.contentOrNull
            return TrackHit(uri, trackTitle, artists.joinToString(", ").ifBlank { artist }, albumName)
        }
        return null
    }

    private suspend fun firstTrackUri(albumId: String, token: String): String? {
        val body = canvasGet(
            "$ALBUM_TRACKS_URL/$albumId/tracks",
            authHeaders(token) + ("User-Agent" to CANVAS_UA),
        ) ?: return null
        val root = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
        return root["items"]?.jsonArray?.firstOrNull()
            ?.jsonObject?.get("uri")?.jsonPrimitive?.contentOrNull
    }

    private suspend fun authHeaders(token: String): Map<String, String> {
        val headers = mutableMapOf("Authorization" to "Bearer $token", "User-Agent" to CANVAS_UA)
        SpotifyToken.clientToken()?.let { headers["Client-Token"] = it }
        return headers
    }

    private fun isMatch(gotName: String, gotArtists: List<String>, wantName: String, wantArtist: String): Boolean {
        if (gotName.normalizeForMatch() != wantName.normalizeForMatch()) return false
        val wanted = splitArtists(wantArtist)
        val credited = gotArtists.map { it.normalizeForMatch() }.filter { it.isNotBlank() }
        if (wanted.isEmpty() || credited.isEmpty()) return false
        return wanted.all { want -> credited.any { it == want } }
    }

    private data class CanvasHit(val id: String?, val url: String, val trackUri: String?)

    private suspend fun fetchCanvasUrl(trackUri: String, token: String): String? {
        val requestBody = encodeCanvasRequest(trackUri)
        val headers = authHeaders(token) + mapOf(
            "Accept" to "application/protobuf",
            "Accept-Language" to "en",
            "User-Agent" to SPOTIFY_APP_UA,
        )
        val response = runCatching {
            Http.postBytes(CANVAS_URL, requestBody, "application/protobuf", headers)
        }.getOrNull() ?: return null
        val bytes = response.body?.takeIf { response.status in 200..299 } ?: return null

        val hits = decodeCanvasResponse(bytes)
        val structured = hits.firstOrNull { it.trackUri == trackUri }?.url ?: hits.firstOrNull()?.url
        if (structured != null) return structured
        return CANVAS_URL_REGEX.find(bytes.decodeToString())?.value
            ?: CANVAS_URL_REGEX.find(bytes.latin1())?.value
    }

    private fun encodeCanvasRequest(trackUri: String): ByteArray {
        val track = protoString(1, trackUri)
        return protoBytes(1, track)
    }

    private fun decodeCanvasResponse(bytes: ByteArray): List<CanvasHit> = runCatching {
        val hits = mutableListOf<CanvasHit>()
        val input = ProtoReader(bytes)
        while (!input.isAtEnd) {
            val tag = input.readTag()
            if (tag == 0) break
            if (tag ushr 3 == 1) {
                decodeCanvas(input.readBytes())?.let(hits::add)
            } else {
                input.skipField(tag)
            }
        }
        hits
    }.getOrElse { emptyList() }

    private fun decodeCanvas(bytes: ByteArray): CanvasHit? = runCatching {
        var id: String? = null
        var url: String? = null
        var trackUri: String? = null
        val input = ProtoReader(bytes)
        while (!input.isAtEnd) {
            val tag = input.readTag()
            if (tag == 0) break
            when (tag ushr 3) {
                1 -> id = input.readString()
                2 -> url = input.readString()
                5 -> trackUri = input.readString()
                else -> input.skipField(tag)
            }
        }
        url?.let { CanvasHit(id, it, trackUri) }
    }.getOrNull()
}

private fun protoString(field: Int, value: String): ByteArray = protoBytes(field, value.encodeToByteArray())

private fun protoBytes(field: Int, value: ByteArray): ByteArray {
    val key = protoVarint((field shl 3) or 2)
    val len = protoVarint(value.size)
    return key + len + value
}

private fun protoVarint(value: Int): ByteArray {
    var v = value
    val out = ArrayList<Byte>(5)
    while ((v and 0x7F.inv()) != 0) {
        out += ((v and 0x7F) or 0x80).toByte()
        v = v ushr 7
    }
    out += v.toByte()
    return out.toByteArray()
}

private class ProtoReader(private val bytes: ByteArray) {
    private var pos = 0
    val isAtEnd: Boolean get() = pos >= bytes.size

    fun readTag(): Int = readVarint().toInt()

    fun readBytes(): ByteArray {
        val len = readVarint().toInt()
        val start = pos
        pos = (pos + len).coerceAtMost(bytes.size)
        return bytes.copyOfRange(start, pos)
    }

    fun readString(): String = readBytes().decodeToString()

    fun skipField(tag: Int) {
        when (tag and 7) {
            0 -> readVarint()
            1 -> pos = (pos + 8).coerceAtMost(bytes.size)
            2 -> readBytes()
            5 -> pos = (pos + 4).coerceAtMost(bytes.size)
            else -> pos = bytes.size
        }
    }

    private fun readVarint(): Long {
        var result = 0L
        var shift = 0
        while (pos < bytes.size) {
            val b = bytes[pos++].toInt() and 0xFF
            result = result or ((b and 0x7F).toLong() shl shift)
            if (b and 0x80 == 0) break
            shift += 7
        }
        return result
    }
}

private fun ByteArray.latin1(): String = buildString(size) {
    for (b in this@latin1) append((b.toInt() and 0xFF).toChar())
}

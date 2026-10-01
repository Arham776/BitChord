package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.HttpStatusException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * Apple Music motion artwork — the 3D glassy animated sleeves the web player
 * shows, exposed on the catalog API as `editorialVideo`.
 *
 * Two problems to solve: the endpoint needs a bearer token scraped from the
 * web player's JS bundle (it is not on the HTML page), and a free-text search
 * will return a plausible-looking wrong album, so hits are scored and the
 * motion clip is taken off the album record rather than trusted inline.
 */
object AppleMusicCanvas {
    private const val AMP = "https://amp-api.music.apple.com/v1/catalog"
    private const val WEB = "https://music.apple.com/us/browse"
    private const val MIN_SCORE = 12
    private const val TOKEN_RETRY_MS = 30_000L
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val lock = Mutex()

    @kotlin.concurrent.Volatile private var cachedToken: String? = null
    @kotlin.concurrent.Volatile private var tokenExpiresAtMs = 0L
    @kotlin.concurrent.Volatile private var retryTokenAfterMs = 0L
    private val rejected = mutableSetOf<String>()

    suspend fun search(title: String, artist: String, album: String?): CanvasArtworkDto? {
        val term = buildString {
            if (!title.contains(artist, ignoreCase = true)) append(artist).append(' ')
            append(title)
            if (!album.isNullOrBlank() && !title.contains(album, ignoreCase = true)) {
                append(' ').append(album)
            }
        }
        val body = catalogGet(
            "$AMP/us/search",
            mapOf(
                "term" to term,
                "types" to "songs",
                "limit" to "10",
                "extend" to "editorialVideo",
                "include" to "albums",
            ),
        ) ?: return null
        val hits = runCatching {
            json.parseToJsonElement(body).jsonObject["results"]?.jsonObject
                ?.get("songs")?.jsonObject?.get("data")?.jsonArray
        }.getOrNull() ?: return null

        val ranked = hits.mapNotNull { el ->
            val song = el as? JsonObject ?: return@mapNotNull null
            val score = score(song, title, artist, album) ?: return@mapNotNull null
            score to song
        }.sortedByDescending { it.first }

        for ((hitScore, song) in ranked) {
            if (hitScore < MIN_SCORE) break
            val attributes = song["attributes"]?.jsonObject ?: continue
            val songName = attributes["name"]?.jsonPrimitive?.contentOrNull
            val songArtist = attributes["artistName"]?.jsonPrimitive?.contentOrNull
            val albumName = attributes["albumName"]?.jsonPrimitive?.contentOrNull
            attributes["editorialVideo"]?.jsonObject?.let { video ->
                motionUrls(video)?.let { (primary, alternate) ->
                    return CanvasArtworkDto(
                        url = primary,
                        fallbackUrl = alternate,
                        title = songName,
                        artist = songArtist,
                        album = albumName,
                        source = "apple",
                    )
                }
            }
            val albumId = albumId(song) ?: continue
            fetchAlbum(albumId, songName, songArtist)?.let { return it }
        }
        return null
    }

    /**
     * Motion artwork for a release rather than a track, for the album page.
     * Albums carry `editorialVideo` inline on the search result.
     */
    suspend fun searchAlbum(album: String, artist: String): CanvasArtworkDto? {
        val term = if (album.contains(artist, ignoreCase = true)) album else "$artist $album"
        val body = catalogGet(
            "$AMP/us/search",
            mapOf(
                "term" to term,
                "types" to "albums",
                "limit" to "10",
                "extend" to "editorialVideo",
            ),
        ) ?: return null
        val hits = runCatching {
            json.parseToJsonElement(body).jsonObject["results"]?.jsonObject
                ?.get("albums")?.jsonObject?.get("data")?.jsonArray
        }.getOrNull() ?: return null

        val ranked = hits.mapNotNull { el ->
            val record = el as? JsonObject ?: return@mapNotNull null
            val score = score(record, album, artist, album, albumIsSelf = true)
                ?: return@mapNotNull null
            score to record
        }.sortedByDescending { it.first }

        for ((hitScore, record) in ranked) {
            if (hitScore < MIN_SCORE) break
            val attributes = record["attributes"]?.jsonObject ?: continue
            val name = attributes["name"]?.jsonPrimitive?.contentOrNull
            if (name != null && isCompilation(name)) continue
            val video = attributes["editorialVideo"]?.jsonObject ?: continue
            val (primary, alternate) = motionUrls(video) ?: continue
            return CanvasArtworkDto(
                url = primary,
                fallbackUrl = alternate,
                title = name,
                artist = attributes["artistName"]?.jsonPrimitive?.contentOrNull,
                album = name,
                source = "apple",
            )
        }
        return null
    }

    private suspend fun fetchAlbum(
        albumId: String,
        songTitle: String?,
        songArtist: String?,
    ): CanvasArtworkDto? {
        val body = catalogGet(
            "$AMP/us/albums/$albumId",
            mapOf("extend" to "editorialVideo"),
        ) ?: return null
        val album = runCatching {
            json.parseToJsonElement(body).jsonObject["data"]?.jsonArray?.firstOrNull()?.jsonObject
        }.getOrNull() ?: return null
        val attributes = album["attributes"]?.jsonObject ?: return null
        val albumName = attributes["name"]?.jsonPrimitive?.contentOrNull.orEmpty()
        if (isCompilation(albumName)) return null
        val video = attributes["editorialVideo"]?.jsonObject ?: return null
        val (primary, alternate) = motionUrls(video) ?: return null
        return CanvasArtworkDto(
            url = primary,
            fallbackUrl = alternate,
            title = songTitle,
            artist = songArtist ?: attributes["artistName"]?.jsonPrimitive?.contentOrNull,
            album = albumName,
            source = "apple",
        )
    }

    private fun albumId(song: JsonObject): String? {
        val fromRelationship = song["relationships"]?.jsonObject
            ?.get("albums")?.jsonObject
            ?.get("data")?.jsonArray?.firstOrNull()
            ?.jsonObject?.get("id")?.jsonPrimitive?.contentOrNull
        if (fromRelationship != null) return fromRelationship.takeUnless { it.startsWith("pl.") }
        val url = song["attributes"]?.jsonObject?.get("url")?.jsonPrimitive?.contentOrNull ?: return null
        return url.substringAfter("/album/", "")
            .substringBefore("?")
            .substringAfterLast("/")
            .takeIf { it.isNotBlank() && it.all(Char::isDigit) }
    }

    /**
     * Square rendition first — it fills a square sleeve without cropping.
     * The tall clip is the same motion framed for a phone, kept as retry.
     */
    private fun motionUrls(video: JsonObject): Pair<String, String?>? {
        fun link(key: String): String? = video[key]?.jsonObject?.let { asset ->
            asset["video"]?.jsonPrimitive?.contentOrNull
                ?: asset["videoUrl"]?.jsonPrimitive?.contentOrNull
                ?: asset["hlsUrl"]?.jsonPrimitive?.contentOrNull
                ?: asset["url"]?.jsonPrimitive?.contentOrNull
        }?.takeIf { it.isNotBlank() }
        val square = link("motionDetailSquare") ?: link("motionSquareVideo1x1")
        val raw = link("motionDetailRaw")
        val tall = link("motionDetailTall") ?: link("motionTallVideo3x4")
        val primary = square ?: raw ?: tall ?: return null
        val alternate = listOfNotNull(square, raw, tall).firstOrNull { it != primary }
        return primary to alternate
    }

    private fun score(
        song: JsonObject,
        title: String,
        artist: String,
        album: String?,
        albumIsSelf: Boolean = false,
    ): Int? {
        val attributes = song["attributes"]?.jsonObject ?: return null
        val hitName = attributes["name"]?.jsonPrimitive?.contentOrNull.orEmpty()
        val hitArtist = attributes["artistName"]?.jsonPrimitive?.contentOrNull.orEmpty()
        val hitAlbum = if (albumIsSelf) hitName else {
            attributes["albumName"]?.jsonPrimitive?.contentOrNull.orEmpty()
        }
        if (isCompilation(hitName) || isCompilation(hitAlbum)) return null
        val wanted = splitArtists(artist)
        val credited = splitArtists(hitArtist)
        if (wanted.isEmpty() || credited.isEmpty()) return null
        if (!wanted.all { want -> credited.any { it == want } }) return null
        var value = 10
        val wantTitle = title.normalizeForMatch()
        val hitTitle = hitName.normalizeForMatch()
        value += when {
            hitTitle == wantTitle -> 15
            hitTitle.contains(wantTitle) || wantTitle.contains(hitTitle) -> 7
            else -> -10
        }
        if (!album.isNullOrBlank() && hitAlbum.isNotBlank()) {
            val wantAlbum = album.normalizeForMatch()
            val gotAlbum = hitAlbum.normalizeForMatch()
            value += when {
                gotAlbum == wantAlbum -> 20
                gotAlbum.contains(wantAlbum) || wantAlbum.contains(gotAlbum) -> 10
                else -> 0
            }
        }
        for (word in EDITION_WORDS) {
            val inWanted = title.contains(word, ignoreCase = true)
            val inHit = hitName.contains(word, ignoreCase = true)
            if (inWanted && inHit) value += 5 else if (inHit) value -= 3
        }
        return value
    }

    private val EDITION_WORDS =
        listOf("deluxe", "expanded", "remastered", "remix", "version", "edit", "mix", "bonus")

    private fun isCompilation(name: String): Boolean {
        val lower = name.lowercase()
        return COMPILATION_MARKERS.any { lower.contains(it) }
    }

    private val COMPILATION_MARKERS = listOf(
        "playlist", "set list", "essentials", "dj mix", "mixed",
        "apple music", "today's hits", "session",
    )

    private suspend fun catalogGet(url: String, query: Map<String, String>): String? =
        readCanvasCatalog(token = { token() }, reject = { reject(it) }) { bearer ->
            Http.getText(url, headers = authHeaders(bearer), query = query, timeoutMillis = 8_000)
        }

    private fun authHeaders(bearer: String) = mapOf(
        "Authorization" to "Bearer $bearer",
        "Origin" to "https://music.apple.com",
        "Referer" to "https://music.apple.com/",
        "User-Agent" to CANVAS_UA,
    )

    private suspend fun reject(bearer: String) {
        lock.withLock {
            rejected += bearer
            if (cachedToken == bearer) {
                cachedToken = null
                tokenExpiresAtMs = 0L
            }
        }
    }

    private suspend fun token(): String? = lock.withLock {
        val now = currentTimeMs()
        cachedToken?.let { if (now < tokenExpiresAtMs - 60_000) return it }
        if (now < retryTokenAfterMs) return null

        val html = canvasGet(WEB) ?: run {
            retryTokenAfterMs = now + TOKEN_RETRY_MS
            return null
        }
        val scripts = Regex("""/assets/index(?:-legacy)?[~-][A-Za-z0-9_-]+\.js""")
            .findAll(html).map { it.value }.distinct().toList()
        for (path in scripts) {
            val script = canvasGet("https://music.apple.com$path") ?: continue
            val candidates = Regex("""ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+""")
                .findAll(script)
                .map { it.value }
                .distinct()
                .filter { it !in rejected }
                .mapNotNull { jwt -> jwtExpiryMs(jwt)?.let { jwt to it } }
                .filter { it.second > now }
                .toList()
            if (candidates.isEmpty()) continue
            val (jwt, expiresAt) = candidates.firstOrNull { isWebPlayerToken(it.first) }
                ?: candidates.first()
            cachedToken = jwt
            tokenExpiresAtMs = expiresAt
            return jwt
        }
        retryTokenAfterMs = now + TOKEN_RETRY_MS
        null
    }

    private fun isWebPlayerToken(jwt: String): Boolean = runCatching {
        val parts = jwt.split(".")
        val header = decodeJwtPart(parts[0])
        val payload = decodeJwtPart(parts[1])
        header.contains("WebPlayKid") || payload.contains("AMPWebPlay")
    }.getOrDefault(false)

    private fun jwtExpiryMs(jwt: String): Long? = runCatching {
        val payload = decodeJwtPart(jwt.split(".")[1])
        val seconds = Regex(""""exp"\s*:\s*(\d+)""").find(payload)?.groupValues?.get(1)
        seconds?.toLong()?.times(1000)
    }.getOrNull()

    @OptIn(ExperimentalEncodingApi::class)
    private fun decodeJwtPart(part: String): String {
        val padded = part.padEnd(part.length + (4 - part.length % 4) % 4, '=')
        return Base64.UrlSafe.decode(padded).decodeToString()
    }

    private fun currentTimeMs(): Long = canvasNowMs()
}

/** A rejected provider token gets one fresh read; network errors keep it intact. */
internal suspend fun readCanvasCatalog(
    token: suspend () -> String?,
    reject: suspend (String) -> Unit,
    request: suspend (String) -> String,
): String? {
    repeat(2) {
        val bearer = token() ?: return null
        try {
            return request(bearer)
        } catch (error: HttpStatusException) {
            if (error.status != 401) return null
            reject(bearer)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            return null
        }
    }
    return null
}

internal suspend fun canvasGet(url: String, extraHeaders: Map<String, String> = emptyMap()): String? {
    val headers = mapOf("User-Agent" to CANVAS_UA) + extraHeaders
    return runCatching { Http.getText(url, headers = headers, timeoutMillis = 8_000) }.getOrNull()
}

internal suspend fun canvasGetWithStatus(
    url: String,
    extraHeaders: Map<String, String> = emptyMap(),
    query: Map<String, String> = emptyMap(),
): Pair<Int, String?> {
    val headers = mapOf("User-Agent" to CANVAS_UA) + extraHeaders
    val raw = runCatching {
        Http.getRaw(url, headers = headers, query = query, timeoutMillis = 8_000)
    }.getOrNull() ?: return -1 to null
    return raw.status to raw.body?.takeIf { raw.status in 200..299 }
}

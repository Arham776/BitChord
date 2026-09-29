package com.music.bitchord.data.lyrics

import com.music.bitchord.data.crypto.HmacSha256
import io.ktor.http.encodeURLQueryComponent
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * Line-synced lyrics from Musixmatch's own web client API.
 *
 * ## The endpoint no longer issues tokens
 *
 * Checked on 26 September 2026: `token.get` answers
 * `status_code: 401, hint: "upgrade"` for the `web-desktop-app-v1.0` app id and the
 * shared signing secret, which is what upstream uses and what this port uses. No
 * token means no search and no subtitle, so this source answers nothing at all.
 *
 * The failure is handled rather than papered over — [signedGet] gives up cleanly and
 * the race carries on to the next source — and it is written down because the symptom
 * is indistinguishable from "Musixmatch has never heard of this song", which is what
 * it will look like to a listener and to the next person to check. A paid key is the
 * only way back, and there is nothing to configure on this side of it.
 */
object Musixmatch {

    private const val BASE = "https://apic.musixmatch.com/ws/1.1"
    private const val SIGNING_SECRET = "RJDefUswhwjkZDeM"

    private val tokenMutex = Mutex()
    @kotlin.concurrent.Volatile private var cachedToken: String? = null

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
    ): List<LyricLineDto>? {
        val seconds = (durationMs / 1000).toInt()
        val track = bestTrack(title, artist, seconds) ?: return null
        val subtitle = if (track.hasSubtitles == 1) fetchSubtitle(track.trackId) else null
        val lrc = subtitle?.let(::subtitleToLrc)?.takeIf { it.isNotBlank() } ?: return null
        return LrcLib.parseLrc(lrc).takeIf { it.isNotEmpty() }
    }

    private suspend fun bestTrack(title: String, artist: String, seconds: Int): Track? {
        val tracks = searchTrack(title, artist) ?: return null
        val durationMs = seconds.toLong() * 1000L
        return tracks.mapNotNull { track ->
            score(track, title, artist, durationMs)?.let { track to it }
        }.maxByOrNull { it.second }?.first
    }

    private fun score(track: Track, title: String, artist: String, durationMs: Long): Int? =
        LyricsMatching.candidateScore(
            wantedTitle = title,
            wantedArtist = artist,
            wantedDurationMs = durationMs,
            candidateTitle = track.trackName,
            candidateArtist = track.artistName,
            candidateDurationMs = track.trackLength?.toLong()?.times(1000L) ?: 0L,
            requireArtist = true,
        )

    private suspend fun searchTrack(title: String, artist: String): List<Track>? {
        val response = signedGet { token ->
            queryUrl(
                "$BASE/track.search",
                listOf(
                    "app_id" to "web-desktop-app-v1.0",
                    "q_track" to title,
                    "q_artist" to artist,
                    "f_has_lyrics" to "1",
                    "s_track_rating" to "desc",
                    "quorum_factor" to "1",
                    "page_size" to "10",
                    "page" to "1",
                    "usertoken" to token,
                ),
            )
        } ?: return null
        val body = runCatching {
            lyricsJson.decodeFromString(Envelope.serializer(TrackSearchBody.serializer()), response)
        }.getOrNull() ?: return null
        return body.message.body?.trackList?.map { it.track }
    }

    private suspend fun fetchSubtitle(trackId: Long): String? {
        val response = signedGet { token ->
            queryUrl(
                "$BASE/track.subtitle.get",
                listOf(
                    "app_id" to "web-desktop-app-v1.0",
                    "track_id" to trackId.toString(),
                    "subtitle_format" to "mxm",
                    "usertoken" to token,
                ),
            )
        } ?: return null
        return runCatching {
            lyricsJson.decodeFromString(Envelope.serializer(SubtitleBody.serializer()), response)
        }.getOrNull()?.message?.body?.subtitle?.subtitleBody
    }

    private fun subtitleToLrc(subtitleBody: String): String {
        val lines = runCatching { lyricsJson.decodeFromString<List<SubtitleLine>>(subtitleBody) }
            .getOrNull() ?: return ""
        return buildString {
            for (line in lines) {
                if (line.text.isBlank()) continue
                val totalMs = (line.time.total * 1000).toLong()
                val minutes = totalMs / 1000 / 60
                val seconds = (totalMs / 1000) % 60
                val millis = totalMs % 1000
                appendLine(
                    "[" + minutes.toString().padStart(2, '0') +
                        ":" + seconds.toString().padStart(2, '0') +
                        "." + millis.toString().padStart(3, '0') + "]" + line.text,
                )
            }
        }.trim()
    }

    private suspend fun signedGet(buildUrl: (token: String) -> String): String? {
        val token = getToken() ?: return null
        val first = lyricsGet(sign(buildUrl(token)))
        if (first != null && !looksUnauthorized(first)) return first

        cachedToken = null
        val fresh = getToken() ?: return null
        return lyricsGet(sign(buildUrl(fresh)))
    }

    private fun looksUnauthorized(body: String): Boolean =
        runCatching { lyricsJson.decodeFromString(Envelope.serializer(JsonElement.serializer()), body) }
            .getOrNull()?.message?.header?.statusCode?.let { it == 401 || it == 402 } ?: false

    private suspend fun getToken(): String? = cachedToken ?: tokenMutex.withLock {
        cachedToken ?: fetchToken()?.also { cachedToken = it }
    }

    private suspend fun fetchToken(): String? {
        val url = queryUrl("$BASE/token.get", listOf("app_id" to "web-desktop-app-v1.0"))
        val body = lyricsGet(sign(url)) ?: return null
        return runCatching {
            lyricsJson.decodeFromString(Envelope.serializer(TokenBody.serializer()), body)
        }.getOrNull()?.message?.body?.userToken
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun sign(url: String): String {
        val date = utcYyyyMMdd(nowMs())
        val raw = HmacSha256.bytes(
            SIGNING_SECRET.encodeToByteArray(),
            "$url$date".encodeToByteArray(),
        )
        val signature = Base64.Default.encode(raw)
        return "$url&signature=${signature.encodeURLQueryComponent()}&signature_protocol=sha256"
    }

    private fun queryUrl(base: String, params: List<Pair<String, String>>): String {
        val q = params.joinToString("&") { (k, v) ->
            "${k.encodeURLQueryComponent()}=${v.encodeURLQueryComponent()}"
        }
        return "$base?$q"
    }

    private fun nowMs(): Long = com.music.bitchord.data.canvas.canvasNowMs()

    /**
     * UTC `yyyyMMdd` from epoch milliseconds (Howard Hinnant civil_from_days).
     */
    internal fun utcYyyyMMdd(epochMs: Long): String {
        val z = epochMs.floorDiv(86_400_000L)
        var days = z + 719468
        val era = if (days >= 0) days / 146097 else (days - 146096) / 146097
        val doe = (days - era * 146097).toInt()
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = mp + if (mp < 10) 3 else -9
        val year = y + if (m <= 2) 1 else 0
        return year.toString().padStart(4, '0') +
            m.toString().padStart(2, '0') +
            d.toString().padStart(2, '0')
    }

    @Serializable
    private data class Envelope<T>(val message: Message<T>)

    @Serializable
    private data class Message<T>(val header: Header, val body: T? = null)

    @Serializable
    private data class Header(@SerialName("status_code") val statusCode: Int = 0)

    @Serializable
    private data class TokenBody(@SerialName("user_token") val userToken: String)

    @Serializable
    private data class TrackSearchBody(@SerialName("track_list") val trackList: List<TrackWrapper> = emptyList())

    @Serializable
    private data class TrackWrapper(val track: Track)

    @Serializable
    private data class Track(
        @SerialName("track_id") val trackId: Long,
        @SerialName("track_name") val trackName: String,
        @SerialName("artist_name") val artistName: String = "",
        @SerialName("track_length") val trackLength: Int? = null,
        @SerialName("has_subtitles") val hasSubtitles: Int = 0,
    )

    @Serializable
    private data class SubtitleBody(val subtitle: Subtitle? = null)

    @Serializable
    private data class Subtitle(@SerialName("subtitle_body") val subtitleBody: String)

    @Serializable
    private data class SubtitleLine(val text: String, val time: SubtitleTime)

    @Serializable
    private data class SubtitleTime(val total: Double)
}

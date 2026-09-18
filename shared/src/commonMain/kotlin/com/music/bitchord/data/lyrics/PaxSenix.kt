package com.music.bitchord.data.lyrics

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.abs

/**
 * Word-timed lyrics via lyrics.paxsenix.org, a public proxy in front of
 * Apple Music's catalogue.
 */
object PaxSenix {

    private const val PROXY = "https://lyrics.paxsenix.org"
    private const val APPLE_SEARCH = "https://amp-api.music.apple.com/v1/catalog/us/search"
    private const val DURATION_TOLERANCE_SECONDS = 10

    private val tokenMutex = Mutex()
    @kotlin.concurrent.Volatile private var cachedToken: String? = null

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? {
        val seconds = (durationMs / 1000).toInt()
        val query = listOfNotNull(title.cleaned(), artist.cleaned().takeIf { it.isNotBlank() })
            .joinToString(" ")
        val results = search(query) ?: return null
        val best = results
            .filter { track ->
                val trackSeconds = track.durationSeconds
                seconds <= 0 || trackSeconds == null || abs(trackSeconds - seconds) <= DURATION_TOLERANCE_SECONDS
            }
            .maxByOrNull { score(it, title, artist) }
            ?: return null

        return fetchLyrics(best.id)
    }

    private fun score(track: AppleTrack, title: String, artist: String): Double {
        val name = track.attributes.name.trim().lowercase()
        val targetTitle = title.trim().lowercase()
        val artistName = track.attributes.artistName.trim().lowercase()
        val targetArtist = artist.trim().lowercase()
        var score = 0.0
        score += when {
            name == targetTitle -> 80.0
            name.contains(targetTitle) || targetTitle.contains(name) -> 40.0
            else -> 0.0
        }
        if (artistName.contains(targetArtist) || targetArtist.contains(artistName)) score += 40.0
        return score
    }

    private fun String.cleaned(): String = replace(
        Regex(
            """\s*[(\[](official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster\w*|live|version|""" +
                """feat\.?|ft\.?)[^)\]]*[)\]]""",
            RegexOption.IGNORE_CASE,
        ),
        "",
    ).trim()

    private suspend fun search(query: String): List<AppleTrack>? {
        val token = getToken() ?: return null
        val body = lyricsGetAuthorized(
            APPLE_SEARCH,
            token,
            query = mapOf(
                "term" to query,
                "types" to "songs",
                "limit" to "10",
                "l" to "en-US",
            ),
        ) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(AppleSearchResponse.serializer(), body) }.getOrNull()
        return response?.results?.songs?.data
    }

    private suspend fun fetchLyrics(appleId: String): List<LyricLineDto>? {
        val body = lyricsGet("$PROXY/apple-music/lyrics", query = mapOf("id" to appleId)) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(LyricsResponse.serializer(), body) }.getOrNull()
            ?: return null

        response.ttmlContent?.takeIf { it.isNotBlank() }?.let { ttml ->
            TtmlLyrics.parse(ttml).takeIf { it.isNotEmpty() }?.let { return it }
        }
        response.elrcMultiPerson?.takeIf { it.isNotBlank() }?.let { elrc ->
            EnhancedLrc.parse(elrc).takeIf { it.isNotEmpty() }?.let { return it }
        }
        response.elrc?.takeIf { it.isNotBlank() }?.let { elrc ->
            EnhancedLrc.parse(elrc).takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    private suspend fun getToken(): String? = cachedToken ?: tokenMutex.withLock {
        cachedToken ?: scrapeToken()?.also { cachedToken = it }
    }

    private suspend fun scrapeToken(): String? {
        val home = lyricsGet("https://music.apple.com/us/new") ?: return null
        val scriptPath = INDEX_JS.find(home)?.value ?: return null
        val script = lyricsGet("https://music.apple.com$scriptPath") ?: return null
        return TOKEN.find(script)?.value
    }

    private val INDEX_JS = Regex("""/assets/index~[^"]+\.js""")
    private val TOKEN = Regex("""eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+""")

    @Serializable
    private data class AppleSearchResponse(val results: Results = Results())

    @Serializable
    private data class Results(val songs: Songs? = null)

    @Serializable
    private data class Songs(val data: List<AppleTrack> = emptyList())

    @Serializable
    private data class AppleTrack(val id: String, val attributes: Attributes) {
        val durationSeconds: Int? get() = attributes.durationInMillis?.let { (it / 1000).toInt() }
    }

    @Serializable
    private data class Attributes(
        val name: String,
        val artistName: String,
        @SerialName("durationInMillis") val durationInMillis: Long? = null,
    )

    @Serializable
    private data class LyricsResponse(
        val ttmlContent: String? = null,
        val elrc: String? = null,
        val elrcMultiPerson: String? = null,
    )
}

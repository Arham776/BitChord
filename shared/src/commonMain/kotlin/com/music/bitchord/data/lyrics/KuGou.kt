package com.music.bitchord.data.lyrics

import kotlinx.serialization.Serializable
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.math.abs
import kotlin.math.min

/**
 * Line-synced lyrics from KuGou's public mobile/lyrics endpoints.
 */
object KuGou {

    private const val DURATION_TOLERANCE_SECONDS = 8

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? {
        val keyword = keyword(title, artist, album)
        val seconds = (durationMs / 1000).toInt()

        val candidate = searchSongs(keyword, seconds)?.firstNotNullOfOrNull { hash ->
            searchLyrics(hash = hash)?.firstOrNull()
        } ?: searchLyrics(keyword = keyword, seconds = seconds)?.firstOrNull()
            ?: return null

        val lrc = download(candidate.id, candidate.accesskey) ?: return null
        return LrcLib.parseLrc(lrc).takeIf { it.isNotEmpty() }
    }

    private suspend fun searchSongs(keyword: Keyword, seconds: Int): List<String>? {
        val body = lyricsGet(
            "https://mobileservice.kugou.com/api/v3/search/song",
            query = mapOf(
                "version" to "9108",
                "plat" to "0",
                "pagesize" to "8",
                "showtype" to "0",
                "keyword" to keyword.query,
            ),
        ) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(SearchSongResponse.serializer(), body) }.getOrNull()
        return response?.data?.info.orEmpty()
            .filter { seconds <= 0 || abs(it.duration - seconds) <= DURATION_TOLERANCE_SECONDS }
            .sortedBy { abs(it.duration - seconds) }
            .map { it.hash }
    }

    private suspend fun searchLyrics(
        hash: String? = null,
        keyword: Keyword? = null,
        seconds: Int = -1,
    ): List<Candidate>? {
        val query = buildMap {
            put("ver", "1")
            put("man", "yes")
            put("client", "pc")
            when {
                hash != null -> put("hash", hash)
                keyword != null -> {
                    put("keyword", keyword.query)
                    if (seconds > 0) put("duration", (seconds * 1000).toString())
                }
                else -> return null
            }
        }
        val body = lyricsGet("https://lyrics.kugou.com/search", query = query) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(SearchLyricsResponse.serializer(), body) }.getOrNull()
        return response?.candidates
    }

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun download(id: String, accessKey: String): String? {
        val body = lyricsGet(
            "https://lyrics.kugou.com/download",
            query = mapOf(
                "fmt" to "lrc",
                "charset" to "utf8",
                "client" to "pc",
                "ver" to "1",
                "id" to id,
                "accesskey" to accessKey,
            ),
        ) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(DownloadResponse.serializer(), body) }.getOrNull()
            ?: return null
        val decoded = runCatching {
            Base64.Default.decode(response.content).decodeToString()
        }.getOrNull() ?: return null
        return decoded.stripCredits()
    }

    private fun keyword(title: String, artist: String, album: String?) = Keyword(
        buildString {
            append(title.stripParenthetical())
            append(" - ")
            append(artist.stripParenthetical())
            if (!album.isNullOrBlank()) {
                append(' ')
                append(album)
            }
        },
    )

    private fun String.stripParenthetical(): String =
        replace(Regex("""[(（].*?[)）]"""), "").trim().ifBlank { this }

    internal fun String.stripCredits(): String {
        val lines = lineSequence().filter { STAMPED.matches(it) }.toList()
        if (lines.isEmpty()) return ""
        val headLimit = min(30, lines.lastIndex)
        val headCut = (headLimit downTo 0).firstOrNull { CREDIT.matches(lines[it]) }?.let { it + 1 } ?: 0
        val body = lines.drop(headCut)
        val tailLimit = min(30, body.lastIndex)
        val tailCut = (0..tailLimit).firstOrNull { CREDIT.matches(body[body.lastIndex - it]) }?.let { it + 1 } ?: 0
        return body.dropLast(tailCut).joinToString("\n")
    }

    private val STAMPED = Regex("""\[\d{2}:\d{2}\.\d{2,3}].*""")
    private val CREDIT = Regex(""".+][^\[]+[:：].+""")

    private class Keyword(val query: String)

    @Serializable
    private data class SearchSongResponse(val data: Data? = null) {
        @Serializable
        data class Data(val info: List<Info> = emptyList())

        @Serializable
        data class Info(val hash: String, val duration: Int = -1)
    }

    @Serializable
    private data class SearchLyricsResponse(val candidates: List<Candidate> = emptyList())

    @Serializable
    private data class Candidate(val id: String, val accesskey: String)

    @Serializable
    private data class DownloadResponse(val content: String = "")
}

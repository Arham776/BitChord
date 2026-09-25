package com.music.bitchord.data.lyrics

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Syllable-timed lyrics from LyricsPlus volunteer mirrors.
 */
object LyricsPlus {
    private val MIRRORS = listOf(
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app",
    )

    @kotlin.concurrent.Volatile private var lastGood: String? = null

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        isrc: String? = null,
    ): List<LyricLineDto>? = coroutineScope {
        val hosts = lastGood
            ?.let { listOf(it) + MIRRORS.filterNot { mirror -> mirror == it } }
            ?: MIRRORS

        val pending = hosts.map { host ->
            host to async { fetch(host, title, artist, durationMs, album, isrc) }
        }.toMutableList()

        try {
            while (pending.isNotEmpty()) {
                val (host, lines) = select {
                    pending.forEach { (host, job) -> job.onAwait { host to it } }
                }
                pending.removeAll { it.first == host }
                if (!lines.isNullOrEmpty()) {
                    lastGood = host
                    return@coroutineScope lines
                }
            }
            null
        } finally {
            pending.forEach { it.second.cancel() }
        }
    }

    private suspend fun fetch(
        host: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        isrc: String?,
    ): List<LyricLineDto>? {
        val query = buildMap {
            put("title", title)
            put("artist", artist)
            val seconds = durationMs / 1000
            if (seconds > 0) put("duration", seconds.toString())
            if (!album.isNullOrBlank()) put("album", album)
            // Sent alongside the name rather than instead of it: unlike
            // [BiniLyrics] this backend aggregates several catalogues, and the
            // ones with no ISRC index still need something to match on.
            if (!isrc.isNullOrBlank()) put("isrc", isrc)
        }
        val body = lyricsGet("$host/v2/lyrics/get", query = query) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(Response.serializer(), body) }.getOrNull()
            ?: return null
        return parse(response).takeIf { it.isNotEmpty() }
    }

    internal fun parse(response: Response): List<LyricLineDto> =
        response.lyrics.orEmpty().mapNotNull { line ->
            val start = line.time ?: return@mapNotNull null
            val words = mergeSyllables(line.syllabus.orEmpty())
            when {
                words.isNotEmpty() -> LyricLineDto(
                    timeMs = minOf(start, words.first().startMs),
                    text = words.joinToString(" ") { it.text },
                    words = words,
                )
                !line.text.isNullOrBlank() -> LyricLineDto(
                    timeMs = start,
                    text = line.text.trim(),
                    sungUntilMs = line.duration?.takeIf { it > 0 }?.let { start + it },
                )
                else -> null
            }
        }.sortedBy { it.timeMs }.withInstrumentalGaps()

    private fun mergeSyllables(syllables: List<Syllable>): List<LyricWordDto> {
        val words = mutableListOf<LyricWordDto>()
        val current = StringBuilder()
        var start = 0L
        var end = 0L

        syllables.forEach { syllable ->
            val text = syllable.text ?: return@forEach
            if (text.isBlank()) return@forEach
            val time = syllable.time ?: return@forEach
            if (current.isEmpty()) start = time
            current.append(text.trim())
            end = time + (syllable.duration ?: 0L)
            if (text.last().isWhitespace()) {
                words += LyricWordDto(start, end, current.toString())
                current.setLength(0)
            }
        }
        if (current.isNotEmpty()) words += LyricWordDto(start, end, current.toString())
        return words
    }

    @Serializable
    internal data class Response(
        val type: String? = null,
        val lyrics: List<Line>? = null,
    )

    @Serializable
    internal data class Line(
        val time: Long? = null,
        val duration: Long? = null,
        val text: String? = null,
        @SerialName("syllabus") val syllabus: List<Syllable>? = null,
    )

    @Serializable
    internal data class Syllable(
        val time: Long? = null,
        val duration: Long? = null,
        val text: String? = null,
    )
}

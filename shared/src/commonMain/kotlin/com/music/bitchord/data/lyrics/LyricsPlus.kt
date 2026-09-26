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

    /**
     * What each mirror has done lately.
     *
     * Process-wide rather than per-call, because the thing worth learning is a
     * property of the *host* — a certificate that does not validate, a
     * deployment that is down — and re-earning that lesson on every track is
     * the wall of TLS failures this exists to stop. See [MirrorHealth] for why
     * the backoff is a doubling one.
     */
    private val health = MirrorHealth()

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        isrc: String? = null,
    ): List<LyricLineDto>? = coroutineScope {
        // Skipped mirrors are left out unless that would leave nothing to try —
        // [MirrorHealth.order] guarantees that, and it is the one thing that must
        // not be got wrong here: an empty host list reports "no lyrics" for a
        // track LyricsPlus has, indistinguishable from a catalogue miss.
        val hosts = health.order(MIRRORS)

        val pending = hosts.map { host ->
            host to async { fetch(host, title, artist, durationMs, album, isrc) }
        }.toMutableList()

        try {
            while (pending.isNotEmpty()) {
                val (host, outcome) = select {
                    pending.forEach { (host, job) -> job.onAwait { host to it } }
                }
                pending.removeAll { it.first == host }
                // The three outcomes are kept apart, because only one of them is
                // a fact about the host: a mirror that answered with nothing is
                // working, and must not be penalised for the track being absent.
                when (outcome) {
                    is FetchOutcome.Unreachable -> health.unreachable(host)
                    is FetchOutcome.Answered -> {
                        health.answered(host)
                        if (outcome.lines.isNotEmpty()) return@coroutineScope outcome.lines
                    }
                }
            }
            null
        } finally {
            pending.forEach { it.second.cancel() }
        }
    }

    /** What one mirror said about one track. See [LyricsAttempt] for why the two
     *  cases are separated. */
    private sealed interface FetchOutcome {
        data class Answered(val lines: List<LyricLineDto>) : FetchOutcome
        data object Unreachable : FetchOutcome
    }

    private suspend fun fetch(
        host: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        isrc: String?,
    ): FetchOutcome {
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
        val attempt = lyricsAttempt("$host/v2/lyrics/get", query = query)
        // A body that will not parse is the host's problem to have, not a fact
        // about the track, and not a reason to write the host off: it is a
        // different shape rather than a broken one, and the next track may well
        // come back in the shape this code understands.
        if (attempt !is LyricsAttempt.Answered) return FetchOutcome.Unreachable
        val response = runCatching {
            lyricsJson.decodeFromString(Response.serializer(), attempt.body)
        }.getOrNull() ?: return FetchOutcome.Answered(emptyList())
        return FetchOutcome.Answered(parse(response))
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

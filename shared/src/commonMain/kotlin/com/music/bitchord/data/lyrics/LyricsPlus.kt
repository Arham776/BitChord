package com.music.bitchord.data.lyrics

import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Syllable-timed lyrics from LyricsPlus volunteer mirrors.
 */
object LyricsPlus {
    private val MIRRORS = listOf(
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app",
        // Last on purpose: this host serves a certificate chain iOS will not
        // accept (chain stops at an intermediate, ATS -9802), so every request
        // to it is a wasted TLS handshake plus a wall of trust-failure noise.
        // [MirrorHealth] still retries it on backoff in case the cert is fixed;
        // the hedged rollout below just never spends the first attempt on it.
        "https://lyricsplus.atomix.one",
    )

    /**
     * Delay before asking the next mirror while the ones already asked have
     * neither answered nor failed. Long enough that the usual case — the last
     * good mirror answering in a few hundred milliseconds — costs a single
     * request instead of six concurrent TLS handshakes, short enough that a
     * hanging mirror only delays the fallback by this much per mirror.
     */
    private const val HEDGE_DELAY_MS = 750L

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

    /**
     * Lyrics for a track, trying mirrors in [MirrorHealth] order with hedged
     * starts rather than all at once.
     *
     * Racing every mirror concurrently meant each track cost up to six TLS
     * handshakes — including one to a host whose certificate deterministically
     * fails, so every track also bought a trust-failure log. Instead the first
     * host goes out alone and the next one starts only if nothing has answered
     * or failed within [HEDGE_DELAY_MS]. A fast failure also starts the next
     * host immediately rather than waiting out the delay, and a host that
     * answers empty fans the rest out at once, since a catalogue miss on one
     * mirror says nothing about the others.
     *
     * Cancellation, penalties and the never-empty guarantee behave as before:
     * anything still in flight is cancelled on return, [FetchOutcome.Unreachable]
     * penalises only the host that failed, and [MirrorHealth.order] always
     * offers at least one host.
     */
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

        val pending = mutableListOf<Pair<String, Deferred<FetchOutcome>>>()
        var nextHost = 0
        fun startNext(): Boolean {
            if (nextHost >= hosts.size) return false
            val host = hosts[nextHost++]
            pending += host to async { fetch(host, title, artist, durationMs, album, isrc) }
            return true
        }
        startNext()

        try {
            while (pending.isNotEmpty() || nextHost < hosts.size) {
                if (pending.isEmpty()) {
                    startNext()
                    continue
                }
                val finished: Pair<String, FetchOutcome>? = select {
                    pending.forEach { (host, job) -> job.onAwait { host to it } }
                    if (nextHost < hosts.size) onTimeout(HEDGE_DELAY_MS) { null }
                }
                if (finished == null) {
                    // Hedge timer: nothing answered or failed in time, ask the
                    // next mirror too.
                    startNext()
                    continue
                }
                val (host, outcome) = finished
                pending.removeAll { it.first == host }
                // The three outcomes are kept apart, because only one of them is
                // a fact about the host: a mirror that answered with nothing is
                // working, and must not be penalised for the track being absent.
                when (outcome) {
                    is FetchOutcome.Unreachable -> {
                        health.unreachable(host)
                        // The slot is free now; ask the next mirror at once
                        // rather than waiting out the hedge delay.
                        startNext()
                    }
                    is FetchOutcome.Answered -> {
                        health.answered(host)
                        if (outcome.lines.isNotEmpty()) return@coroutineScope outcome.lines
                        // Answered empty: fan the rest out at once instead of
                        // trickling, since the track may be on any of them.
                        while (startNext()) { /* all remaining hosts */ }
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

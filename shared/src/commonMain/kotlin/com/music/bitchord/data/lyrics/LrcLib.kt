package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlin.math.abs

/**
 * Port of upstream `data/lyrics/LrcLib.kt` — LRCLIB, free and key-less.
 * Exact `get` first, then fuzzy `search`. Line-synced LRC only.
 */
object LrcLib {

    private const val BASE = "https://lrclib.net/api"
    private const val AGENT = "BitChord (https://github.com/bitchord)"
    private const val MIN_GAP_MS = 4_000L

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun lyrics(title: String, artist: String, durationMs: Long): List<LyricLineDto>? {
        // Strip upload packaging and feature credits, while preserving recording
        // identity markers such as "Live", "Acoustic" and "Remix".
        val cleanTitle = title.forLyricsSearch()
        val cleanArtist = artist.artistForLyricsSearch()
        val seconds = (durationMs / 1000).toInt()
        val exact = runCatching { exactMatch(cleanTitle, cleanArtist, seconds) }.getOrNull()
            ?.takeIf { candidateScore(it, cleanTitle, cleanArtist, durationMs) != null }
            ?.takeIf { !it.syncedLyrics.isNullOrBlank() }
        val record = exact ?: runCatching {
            bestSearchHit(cleanTitle, cleanArtist, seconds, durationMs)
        }.getOrNull()
        val raw = record?.syncedLyrics?.takeIf { it.isNotBlank() } ?: return null
        EnhancedLrc.parse(raw).takeIf { it.isNotEmpty() }?.let { return it }
        return parseLrc(raw).takeIf { it.isNotEmpty() }
    }

    private suspend fun exactMatch(title: String, artist: String, seconds: Int): Track? {
        val body = Http.getText(
            "$BASE/get",
            headers = mapOf("User-Agent" to AGENT),
            query = mapOf(
                "track_name" to title,
                "artist_name" to artist,
                "duration" to seconds.toString(),
            ),
        )
        return runCatching { json.decodeFromString(Track.serializer(), body) }.getOrNull()
    }

    private suspend fun bestSearchHit(
        title: String,
        artist: String,
        seconds: Int,
        durationMs: Long,
    ): Track? {
        val body = Http.getText(
            "$BASE/search",
            headers = mapOf("User-Agent" to AGENT),
            query = mapOf(
                "track_name" to title,
                "artist_name" to artist,
            ),
        )
        val hits = json.parseToJsonElement(body) as? JsonArray ?: return null
        return hits.mapNotNull { it as? JsonObject }
            .mapNotNull { element ->
                val track = runCatching {
                    json.decodeFromJsonElement(Track.serializer(), element)
                }.getOrNull() ?: return@mapNotNull null
                val score = candidateScore(track, title, artist, durationMs) ?: return@mapNotNull null
                if (track.syncedLyrics.isNullOrBlank()) return@mapNotNull null
                track to score
            }
            .maxWithOrNull(
                compareBy<Pair<Track, Int>> { it.second }
                    .thenBy { -(it.first.durationSeconds?.let { length -> abs(length - seconds) } ?: 0.0).toLong() },
            )
            ?.first
    }

    internal fun candidateScore(track: Track, title: String, artist: String, durationMs: Long): Int? =
        LyricsMatching.candidateScore(
            wantedTitle = title,
            wantedArtist = artist,
            wantedDurationMs = durationMs,
            candidateTitle = track.title,
            candidateArtist = track.artistName,
            candidateDurationMs = track.durationSeconds?.let { (it * 1000).toLong() } ?: 0L,
            requireArtist = true,
        )

    @Serializable
    internal data class Track(
        val id: Long? = null,
        val name: String? = null,
        val trackName: String? = null,
        val artistName: String? = null,
        val albumName: String? = null,
        val duration: Double? = null,
        val instrumental: Boolean? = null,
        val plainLyrics: String? = null,
        val syncedLyrics: String? = null,
    ) {
        val title: String? get() = trackName ?: name
        val durationSeconds: Double? get() = duration
    }

    internal fun parseLrc(lrc: String): List<LyricLineDto> {
        var offsetMs = 0L
        val rows = mutableListOf<LyricLineDto>()
        lrc.lineSequence().forEach { raw ->
            OFFSET.find(raw)?.let { match ->
                offsetMs = match.groupValues[1].toLongOrNull() ?: 0L
                return@forEach
            }
            val stamps = STAMP.findAll(raw).toList()
            if (stamps.isEmpty()) return@forEach
            val body = raw.replace(STAMP, "").trim()
            val parsedWords = parseWordRuns(body)
            stamps.forEach { stamp ->
                rows += LyricLineDto(
                    timeMs = (msOf(stamp) + offsetMs).coerceAtLeast(0L),
                    text = body.replace(WORD_STAMP, "").trim(),
                    words = parsedWords.map { word ->
                        word.copy(
                            startMs = (word.startMs + offsetMs).coerceAtLeast(0L),
                            endMs = (word.endMs + offsetMs).coerceAtLeast(0L),
                        )
                    },
                )
            }
        }
        val all = rows.sortedBy { it.timeMs }

        val withInferredWordEnds = all.mapIndexed { index, line ->
            val nextLineStart = all.getOrNull(index + 1)?.timeMs
            val words = line.words.mapIndexed { wordIndex, word ->
                if (word.endMs > word.startMs) return@mapIndexed word
                val nextWord = line.words.getOrNull(wordIndex + 1)?.startMs
                val end = nextWord?.takeIf { it > word.startMs }
                    ?: nextLineStart?.takeIf { it > word.startMs }
                    ?: word.startMs + 800L
                word.copy(endMs = end)
            }
            line.copy(words = words)
        }

        val kept = withInferredWordEnds.filterIndexed { index, line ->
            if (!line.isGap) return@filterIndexed true
            val next = withInferredWordEnds.getOrNull(index + 1) ?: return@filterIndexed true
            next.timeMs - line.timeMs >= MIN_GAP_MS
        }
        val first = kept.firstOrNull() ?: return kept
        val normalized = if (!first.isGap && first.timeMs >= MIN_GAP_MS) {
            listOf(LyricLineDto(0L, "")) + kept
        } else {
            kept
        }
        return LyricsMatching.normalize(normalized)
    }

    private fun parseWordRuns(body: String): List<LyricWordDto> {
        val marks = WORD_STAMP.findAll(body).toList()
        if (marks.isEmpty()) return emptyList()
        val runs = marks.mapIndexed { index, mark ->
            val until = marks.getOrNull(index + 1)?.range?.first ?: body.length
            msOf(mark) to body.substring(mark.range.last + 1, until)
        }
        return runs.mapIndexedNotNull { index, (startMs, text) ->
            if (text.isBlank()) return@mapIndexedNotNull null
            val endMs = runs.getOrNull(index + 1)?.first ?: startMs
            LyricWordDto(startMs = startMs, endMs = maxOf(endMs, startMs), text = text.trim())
        }
    }

    private fun msOf(mark: MatchResult): Long {
        val (minutes, seconds, fraction) = mark.destructured
        val fractionMs = fractionToMs(fraction)
        return minutes.toLong() * 60_000 + seconds.toLong() * 1_000 + fractionMs
    }

    private fun fractionToMs(fraction: String): Long = when (fraction.length) {
        1 -> fraction.toLong() * 100
        2 -> fraction.toLong() * 10
        3 -> fraction.toLong()
        else -> 0L
    }

    private val STAMP = Regex("""\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?]""")
    private val WORD_STAMP = Regex("""<(\d{1,3}):(\d{2})[.:](\d{1,3})>""")
    private val OFFSET = Regex("""\[offset:\s*([+-]?\d+)\s*]""", RegexOption.IGNORE_CASE)
}

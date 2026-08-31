package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
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
        val cleanTitle = title.clean()
        val cleanArtist = artist.clean()
        val seconds = (durationMs / 1000).toInt()
        val synced = runCatching { exactMatch(cleanTitle, cleanArtist, seconds) }.getOrNull()
            ?: runCatching { bestSearchHit(cleanTitle, cleanArtist, seconds) }.getOrNull()
        val raw = synced?.takeIf { it.isNotBlank() } ?: return null
        EnhancedLrc.parse(raw).takeIf { it.isNotEmpty() }?.let { return it }
        return parseLrc(raw).takeIf { it.isNotEmpty() }
    }

    private suspend fun exactMatch(title: String, artist: String, seconds: Int): String? {
        val body = Http.getText(
            "$BASE/get",
            headers = mapOf("User-Agent" to AGENT),
            query = mapOf(
                "track_name" to title,
                "artist_name" to artist,
                "duration" to seconds.toString(),
            ),
        )
        return syncedOf(json.parseToJsonElement(body) as? JsonObject)
    }

    private suspend fun bestSearchHit(title: String, artist: String, seconds: Int): String? {
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
            .filter { !syncedOf(it).isNullOrBlank() }
            .minByOrNull {
                val d = (it["duration"] as? JsonPrimitive)?.doubleOrNull ?: 0.0
                abs(d - seconds)
            }
            ?.let(::syncedOf)
    }

    private fun syncedOf(obj: JsonObject?): String? {
        if (obj == null) return null
        val el = obj["syncedLyrics"] ?: return null
        if (el is JsonNull) return null
        return el.jsonPrimitive.contentOrNull?.takeIf { it.isNotBlank() }
    }

    internal fun parseLrc(lrc: String): List<LyricLineDto> {
        val all = lrc.lineSequence().mapNotNull { line ->
            val match = STAMP.find(line) ?: return@mapNotNull null
            val (minutes, seconds, fraction) = match.destructured
            val fractionMs = when (fraction.length) {
                2 -> fraction.toLong() * 10
                3 -> fraction.toLong()
                else -> 0L
            }
            val body = line.substring(match.range.last + 1).replace(WORD_STAMP, "").trim()
            LyricLineDto(
                timeMs = minutes.toLong() * 60_000 + seconds.toLong() * 1_000 + fractionMs,
                text = body,
            )
        }.sortedBy { it.timeMs }.toList()

        val kept = all.filterIndexed { index, line ->
            if (!line.isGap) return@filterIndexed true
            val next = all.getOrNull(index + 1) ?: return@filterIndexed true
            next.timeMs - line.timeMs >= MIN_GAP_MS
        }
        val first = kept.firstOrNull() ?: return kept
        return if (!first.isGap && first.timeMs >= MIN_GAP_MS) {
            listOf(LyricLineDto(0L, "")) + kept
        } else {
            kept
        }
    }

    private fun String.clean(): String = this
        .replace(NOISE, " ")
        .substringBefore(" | ")
        .replace(Regex("\\s+"), " ")
        .trim()
        .ifBlank { this }

    private val STAMP = Regex("""\[(\d{1,2}):(\d{2})[.:](\d{2,3})]""")
    private val WORD_STAMP = Regex("""<(\d{1,3}):(\d{2})[.:](\d{2,3})>""")
    private val NOISE = Regex(
        """\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^]]*]|""" +
            """\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b""",
        RegexOption.IGNORE_CASE,
    )
}

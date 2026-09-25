package com.music.bitchord.data.lyrics

import com.music.bitchord.data.innertube.Innertube
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The two YouTube sources, and the only ones here that are not guessing.
 *
 * Every other provider in this package is asked for a title, an artist and a
 * length and matches fuzzily, which is why [LyricsRepository] bothers to settle
 * the recording by ISRC first. These two are asked about a *video id* — the exact
 * thing being played — so there is nothing to match and nothing to get wrong. A
 * lyric credited to the wrong song is impossible from here.
 *
 * That is also why they sit where they do in the order: they are right, and they
 * are not synchronised word by word. YouTube Music's Lyrics tab is plain text and
 * the transcript is line-stamped, so a word-synced answer from a real provider
 * beats either.
 */
object YouTubeMusicLyrics {

    suspend fun lyrics(videoId: String): List<LyricLineDto>? = withContext(Dispatchers.Default) {
        if (!isVideoId(videoId)) return@withContext null
        val next = runCatching { Innertube.next(videoId) }.getOrNull() ?: return@withContext null
        val tabs = next.objectsNamed("tabRenderer").toList()
        // The Lyrics tab by name. YouTube has renamed and re-ordered these, so the
        // name is the only stable handle; the positional fallback is for the
        // responses where the name is not localised into anything we recognise.
        val endpoint = tabs
            .firstOrNull { tab -> tab.youtubeStrings().any { it.equals("Lyrics", ignoreCase = true) } }
            ?.objectsNamed("browseEndpoint")?.firstOrNull()
            ?: tabs.drop(1).firstNotNullOfOrNull {
                it.objectsNamed("browseEndpoint").firstOrNull()
            }
            ?: return@withContext null
        val browseId = (endpoint["browseId"] as? JsonPrimitive)?.contentOrNull
            ?: return@withContext null
        val params = (endpoint["params"] as? JsonPrimitive)?.contentOrNull
        val page = runCatching { Innertube.browse(browseId, params) }.getOrNull() ?: return@withContext null
        val shelf = page.objectsNamed("musicDescriptionShelfRenderer").firstOrNull()
            ?: return@withContext null
        val text = shelf["description"]?.youtubeStrings()?.joinToString("").orEmpty().trim()
        text.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { LyricLineDto(timeMs = 0L, text = it) }
            .toList()
            .takeIf { it.isNotEmpty() }
    }
}

/** Timed YouTube transcript/captions for the exact playing video. */
object YouTubeTranscriptLyrics {

    suspend fun lyrics(videoId: String): List<LyricLineDto>? = withContext(Dispatchers.Default) {
        if (!isVideoId(videoId)) return@withContext null
        val response = runCatching { Innertube.transcript(videoId) }.getOrNull()
            ?: return@withContext null
        response.objectsNamed("transcriptCueRenderer").mapNotNull { cue ->
            val start = (cue["startOffsetMs"] as? JsonPrimitive)?.longOrNull
                ?: return@mapNotNull null
            val text = cue["cue"]?.youtubeStrings()?.joinToString("").orEmpty()
                // `♪` is YouTube's marker for music in a caption track, not a
                // lyric. Leaving it in put a music note in the middle of the words
                // on screen, scrolling in time.
                .trim(' ', '\n', '♪')
            text.takeIf { it.isNotEmpty() }?.let { LyricLineDto(timeMs = start, text = it) }
        }.sortedBy { it.timeMs }.toList().takeIf { it.isNotEmpty() }
    }
}

/**
 * Whether this is plausibly a video id.
 *
 * Eleven characters of the URL-safe alphabet. Checked before spending a request,
 * because these are called with whatever the queue entry carried and a local file
 * or a `src:<config>::<track>` key is not something `get_transcript` will have
 * anything to say about.
 */
internal fun isVideoId(value: String): Boolean = VIDEO_ID.matches(value)

private val VIDEO_ID = Regex("""[A-Za-z0-9_-]{11}""")

/**
 * Every object with this key, at any depth.
 *
 * A walk rather than a decode because these are YouTube's own response shapes,
 * which change without notice and have no schema to hold them to. A path would
 * break on a rename; a walk finds the thing wherever it moved to.
 */
private fun JsonElement.objectsNamed(name: String): Sequence<JsonObject> = sequence {
    when (this@objectsNamed) {
        is JsonObject -> for ((key, value) in this@objectsNamed) {
            if (key == name && value is JsonObject) yield(value)
            yieldAll(value.objectsNamed(name))
        }
        is JsonArray -> for (value in this@objectsNamed) yieldAll(value.objectsNamed(name))
        else -> Unit
    }
}

/**
 * The human-readable text at this point in a response.
 *
 * YouTube spells the same thing `text`, `simpleText`, and as a run object with
 * `runs`; which one appears depends on whether the string contains markup.
 *
 * Only *string* primitives count. The walk below reaches every leaf in the
 * subtree, and the response is full of numbers that are not lyrics — durations,
 * counts, ids. Reading those as text put a millisecond timestamp into the middle
 * of a line, scrolling in time with the music.
 */
internal fun JsonElement.youtubeStrings(): List<String> = when (this) {
    is JsonPrimitive ->
        if (isString) contentOrNull?.let(::listOf).orEmpty() else emptyList()
    is JsonArray -> flatMap { it.youtubeStrings() }
    is JsonObject -> {
        val direct = (this["text"] as? JsonPrimitive)?.contentOrNull
            ?: (this["simpleText"] as? JsonPrimitive)?.contentOrNull
        direct?.let(::listOf) ?: values.flatMap { it.youtubeStrings() }
    }
}

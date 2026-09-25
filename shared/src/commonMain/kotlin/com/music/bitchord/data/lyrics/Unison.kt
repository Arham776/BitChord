package com.music.bitchord.data.lyrics

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/**
 * A community-submitted lyrics database, and the only source here whose
 * contents are contributed rather than licensed.
 *
 * That is its whole character. Every other source is a window onto somebody's
 * catalogue — Apple's, Musixmatch's, KuGou's — and carries whatever that
 * catalogue has. This one carries what people have uploaded, which means it
 * occasionally has a track none of the others do, and means its coverage is thin
 * and uneven everywhere else. It sits low in the default order for exactly that
 * reason.
 *
 * Each entry is voted on, and the response says so: a `confidence` and a
 * `voteCount`. Neither is acted on here. A fresh submission is `confidence: "low"`
 * with no votes at all, so refusing those would refuse nearly the whole
 * database, and the alternative to a lightly-voted entry is usually no lyrics
 * rather than better ones.
 *
 * Three shapes come back, and it says which: Apple-style TTML, ordinary
 * line-stamped LRC, or plain text with no timing at all.
 */
object Unison {

    private const val BASE = "https://unison.boidu.dev/lyrics"

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? = withContext(Dispatchers.Default) {
        val query = buildMap {
            put("song", title)
            put("artist", artist)
            if (!album.isNullOrBlank()) put("album", album)
            val seconds = durationMs / 1000
            if (seconds > 0) put("duration", seconds.toString())
        }
        val body = lyricsGet(BASE, query = query) ?: return@withContext null
        val response = runCatching {
            lyricsJson.decodeFromString(Response.serializer(), body)
        }.getOrNull() ?: return@withContext null
        // `success: false` is a miss, not a fault. It is how this database says
        // "I have never heard of that", and treating it as an error would put a
        // failed lookup in the log for every track it does not have.
        if (response.success != true) return@withContext null
        linesOf(response.data ?: return@withContext null)
    }

    /** The three shapes, told apart by what the entry says it is. */
    internal fun linesOf(data: Entry): List<LyricLineDto>? {
        val text = data.lyrics?.takeIf { it.isNotBlank() } ?: return null
        val lines = when {
            data.format.equals(TTML, ignoreCase = true) -> TtmlLyrics.parse(text)
            data.syncType.equals(PLAIN, ignoreCase = true) -> plain(text)
            // Word stamps first: the format field says only "lrc", and an
            // enhanced file is still one. [EnhancedLrc] comes back empty when
            // there are no word stamps in it, which is the signal to fall
            // through rather than a failure.
            else -> EnhancedLrc.parse(text).takeIf { it.isNotEmpty() } ?: LrcLib.parseLrc(text)
        }
        return lines.takeIf { it.isNotEmpty() }
    }

    /**
     * Lyrics with no timing: one line each, all stamped zero, which is how every
     * unsynced source here states the same thing — the panel reads it as words to
     * be scrolled by hand rather than followed.
     */
    private fun plain(text: String): List<LyricLineDto> = text.lineSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .map { LyricLineDto(timeMs = 0, text = it) }
        .toList()

    private const val TTML = "ttml"
    private const val PLAIN = "plain"

    @Serializable
    internal data class Response(
        val success: Boolean? = null,
        val data: Entry? = null,
    )

    @Serializable
    internal data class Entry(
        val song: String? = null,
        val artist: String? = null,
        val album: String? = null,
        val lyrics: String? = null,
        /** `ttml` or `lrc`. */
        val format: String? = null,
        /** `wordsync`, `linesync` or `plain`. */
        val syncType: String? = null,
        val confidence: String? = null,
        val voteCount: Int? = null,
    )
}

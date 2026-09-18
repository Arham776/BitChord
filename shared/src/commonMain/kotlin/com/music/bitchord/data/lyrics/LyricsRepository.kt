package com.music.bitchord.data.lyrics

import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/**
 * Where the player gets its lyrics. Every enabled source is asked at the same
 * time; answers are taken in [order] so a lower-priority source finishing
 * first never preempts one still pending ahead of it.
 */
object LyricsRepository {

    data class Result(val source: LyricsSource, val lines: List<LyricLineDto>)

    suspend fun lyrics(
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        sources: Set<LyricsSource> = LyricsSource.entries.toSet(),
        order: List<LyricsSource> = LyricsSource.entries,
        prioritizeSyllableSync: Boolean = false,
    ): Result? = coroutineScope {
        val sequence = order.filter { it in sources } +
            LyricsSource.entries.filter { it in sources && it !in order }

        val racing: List<Pair<LyricsSource, Deferred<List<LyricLineDto>?>>> = sequence.map { source ->
            source to async { fetch(source, videoId, title, artist, durationMs, album) }
        }

        try {
            var lineSynced: Result? = null
            for ((source, job) in racing) {
                val lines = runCatching { job.await() }.getOrNull() ?: continue
                if (lines.any { it.isWordSynced }) return@coroutineScope result(source, lines)
                if (!prioritizeSyllableSync) return@coroutineScope result(source, lines)
                if (lineSynced == null) lineSynced = result(source, lines)
            }
            lineSynced
        } finally {
            racing.forEach { it.second.cancel() }
        }
    }

    private suspend fun fetch(
        source: LyricsSource,
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
    ): List<LyricLineDto>? = when (source) {
        LyricsSource.BETTER_LYRICS -> BetterLyrics.lyrics(title, artist, durationMs, album)
        LyricsSource.LYRICS_PLUS -> LyricsPlus.lyrics(title, artist, durationMs, album)
        LyricsSource.SIMP_MUSIC -> SimpMusicLyrics.lyrics(videoId, durationMs)
        LyricsSource.LRCLIB -> LrcLib.lyrics(title, artist, durationMs)
        LyricsSource.MUSIXMATCH -> Musixmatch.lyrics(title, artist, durationMs)
        LyricsSource.PAXSENIX -> PaxSenix.lyrics(title, artist, durationMs, album)
        LyricsSource.KUGOU -> KuGou.lyrics(title, artist, durationMs, album)
    }

    private fun result(source: LyricsSource, lines: List<LyricLineDto>) =
        Result(source, lines.withBackgroundVocals())
}

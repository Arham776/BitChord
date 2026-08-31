package com.music.bitchord.data.lyrics

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import com.music.bitchord.data.settings.AppSettings

/**
 * Races BetterLyrics, LyricsPlus and LRCLIB. Word-synced wins when present.
 */
object LyricsBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface LyricsCallback {
        fun onResult(lines: List<LyricLineDto>)
    }

    fun fetch(title: String, artist: String, durationMs: Long, callback: LyricsCallback) {
        fetch(title, artist, durationMs, album = null, callback)
    }

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        callback: LyricsCallback,
    ) {
        scope.launch {
            val lines = runCatching { lyrics(title, artist, durationMs, album, videoId) }.getOrElse { emptyList() }
            callback.onResult(lines)
        }
    }

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        callback: LyricsCallback,
    ) = fetch(title, artist, durationMs, album, videoId = null, callback)

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        videoId: String? = null,
    ): List<LyricLineDto> = coroutineScope {
        val enabled = AppSettings.lyricsSources.value
            .split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        val enabledSet = enabled.toSet()
        val better = async {
            if ("BETTER" in enabledSet) runCatching { BetterLyrics.lyrics(title, artist, durationMs, album) }.getOrNull() else null
        }
        val plus = async {
            if ("PLUS" in enabledSet) runCatching { LyricsPlus.lyrics(title, artist, album) }.getOrNull() else null
        }
        val simp = async {
            if ("SIMP" in enabledSet) runCatching { SimpMusicLyrics.lyrics(videoId.orEmpty(), durationMs) }.getOrNull() else null
        }
        val lrc = async {
            if ("LRCLIB" in enabledSet) runCatching { LrcLib.lyrics(title, artist, durationMs) }.getOrNull() else null
        }
        val jobs = mapOf("BETTER" to better, "PLUS" to plus, "SIMP" to simp, "LRCLIB" to lrc)
        val ordered = enabled.mapNotNull { jobs[it] }.ifEmpty { jobs.values.toList() }
        val candidates = ordered.mapNotNull { it.await() }
        val wordFirst = AppSettings.prioritizeSyllableSync.value
        if (wordFirst) {
            candidates.firstOrNull { lines -> lines.any { it.wordSynced } }
                ?: candidates.maxByOrNull { it.size }
                ?: emptyList()
        } else {
            candidates.firstOrNull() ?: emptyList()
        }
    }
}

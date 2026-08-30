package com.music.bitchord.data.lyrics

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Swift-facing LRCLIB lookup. Upstream races several providers; this is the
 * one that needs no API key and works from Darwin the same way as Innertube.
 */
object LyricsBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface LyricsCallback {
        fun onResult(lines: List<LyricLineDto>)
    }

    fun fetch(title: String, artist: String, durationMs: Long, callback: LyricsCallback) {
        scope.launch {
            val lines = runCatching {
                LrcLib.lyrics(title, artist, durationMs).orEmpty()
            }.getOrElse { emptyList() }
            callback.onResult(lines)
        }
    }
}

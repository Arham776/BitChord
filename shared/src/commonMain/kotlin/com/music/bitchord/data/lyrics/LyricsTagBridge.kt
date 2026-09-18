package com.music.bitchord.data.lyrics

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Lyrics-for-download API (upstream `LyricsTag`).
 *
 * Swift still needs to call [embedSidecar] after a download finishes — or
 * [forTrack] and write [plain] into tags via native-core once that field exists.
 */
object LyricsTagBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface EmbedCallback {
        fun onResult(plain: String?, enhanced: String?)
    }

    fun forTrack(
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        callback: EmbedCallback,
    ) {
        scope.launch {
            val found = runCatching {
                LyricsTag.forTrack(videoId, title, artist, durationMs, album)
            }.getOrNull()
            callback.onResult(found?.plain, found?.enhanced)
        }
    }

    /**
     * Fetch lyrics and write a `.lrc` sidecar next to [audioPath]
     * (`song.m4a` → `song.lrc`).
     */
    fun embedSidecar(
        audioPath: String,
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        callback: EmbedCallback,
    ) {
        scope.launch {
            val found = runCatching {
                LyricsTag.forTrack(videoId, title, artist, durationMs, album)
            }.getOrNull()
            if (found != null) {
                runCatching { writeUtf8File(sidecarPath(audioPath), found.plain) }
            }
            callback.onResult(found?.plain, found?.enhanced)
        }
    }

    internal fun sidecarPath(audioPath: String): String {
        val slash = audioPath.lastIndexOf('/')
        val name = if (slash >= 0) audioPath.substring(slash + 1) else audioPath
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val dir = if (slash >= 0) audioPath.substring(0, slash + 1) else ""
        return dir + stem + ".lrc"
    }
}

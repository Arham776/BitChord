package com.music.bitchord.data.lyrics

import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Races every enabled lyrics source in the user's order.
 *
 * [fetch] keeps the existing Swift callback (lines only).
 * [fetchAttributed] also reports which source won, for "Lyrics by {source}".
 */
object LyricsBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface LyricsCallback {
        fun onResult(lines: List<LyricLineDto>)
    }

    /** Swift: show "Lyrics by {sourceLabel}". Empty [source] means embedded file lyrics. */
    fun interface AttributedLyricsCallback {
        fun onResult(source: String, sourceLabel: String, lines: List<LyricLineDto>)
    }

    fun fetch(title: String, artist: String, durationMs: Long, callback: LyricsCallback) {
        fetch(title, artist, durationMs, album = null, callback)
    }

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        callback: LyricsCallback,
    ) = fetch(title, artist, durationMs, album, videoId = null, callback)

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        callback: LyricsCallback,
    ) = fetchAttributed(title, artist, durationMs, album, videoId, localPath = null) { _, _, lines ->
        callback.onResult(lines)
    }

    /**
     * Same race as [fetch], plus source attribution and an optional local file
     * to read embedded lyrics from first (downloaded/local tracks).
     */
    fun fetchAttributed(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        localPath: String?,
        callback: AttributedLyricsCallback,
    ) {
        scope.launch {
            val (source, lines) = runCatching {
                lookup(title, artist, durationMs, album, videoId, localPath)
            }.getOrElse { null to emptyList() }
            callback.onResult(source?.name.orEmpty(), source?.label.orEmpty(), lines)
        }
    }

    /** Read lyrics already tagged into a local/downloaded file. */
    fun fetchEmbedded(path: String, callback: LyricsCallback) {
        scope.launch {
            val lines = runCatching { EmbeddedLyrics.forPath(path) }.getOrNull().orEmpty()
            callback.onResult(lines)
        }
    }

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        videoId: String? = null,
    ): List<LyricLineDto> = lookup(title, artist, durationMs, album, videoId, localPath = null).second

    private suspend fun lookup(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        localPath: String?,
    ): Pair<LyricsSource?, List<LyricLineDto>> {
        if (!localPath.isNullOrBlank()) {
            EmbeddedLyrics.forPath(localPath)?.let { return null to it }
        }
        if (!AppSettings.syncedLyrics.value) return null to emptyList()
        val sources = AppSettings.lyricsSourcesSet()
        if (sources.isEmpty() || durationMs <= 0L) return null to emptyList()
        val found = LyricsRepository.lyrics(
            videoId = videoId.orEmpty(),
            title = title,
            artist = artist,
            durationMs = durationMs,
            album = album,
            sources = sources,
            order = AppSettings.lyricsSourceOrderList(),
            prioritizeSyllableSync = AppSettings.prioritizeSyllableSync.value,
        )
        return found?.source to found?.lines.orEmpty()
    }
}

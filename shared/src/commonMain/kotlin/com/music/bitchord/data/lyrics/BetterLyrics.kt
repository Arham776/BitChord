package com.music.bitchord.data.lyrics

/**
 * Word-timed TTML from BetterLyrics (no API key).
 *
 * Two endpoints, one host, and they are not the same catalogue: the main one
 * serves Apple Music's timings and Portato serves QQ Music's karaoke timings.
 * Separate entries in the settings because they fail independently — a track
 * one has and the other does not is common, and which of them is worth asking
 * depends on the catalogue rather than on anything the listener sets.
 *
 * ## The Portato endpoint is gone
 *
 * Checked on 26 September 2026: `getLyricsPortato` answers `404 page not found`
 * while `getLyrics` answers normally. The second source therefore never returns
 * anything, and the setting is still here because the endpoint may come back and
 * because removing it would take a listener's saved choice away. Noted so that
 * "Portato never has anything" is not read as a bug in the lookup.
 */
object BetterLyrics {
    private const val BASE = "https://lyrics-api.boidu.dev/getLyrics"
    private const val PORTATO = "https://lyrics-api.boidu.dev/getLyricsPortato"

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? = fetch(BASE, title, artist, durationMs, album)

    /** QQ Music's karaoke timings through BetterLyrics' Portato endpoint. */
    suspend fun portato(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? = fetch(PORTATO, title, artist, durationMs, album)

    private suspend fun fetch(
        endpoint: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
    ): List<LyricLineDto>? {
        val query = buildMap {
            put("s", title)
            put("a", artist)
            val seconds = durationMs / 1000
            if (seconds > 0) put("d", seconds.toString())
            if (!album.isNullOrBlank()) put("al", album)
        }
        val body = lyricsGet(endpoint, query = query) ?: return null
        return ProviderLyrics.parse(body)
    }
}

package com.music.bitchord.data.scrobbling

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.settings.AppSettings

object ListenBrainz {
    private const val API = "https://api.listenbrainz.org/1/submit-listens"

    suspend fun playingNow(artist: String, title: String, album: String?, durationMs: Long, positionMs: Long) {
        submit("playing_now", artist, title, album, durationMs, positionMs, listenedAt = null)
    }

    suspend fun scrobble(artist: String, title: String, album: String?, durationMs: Long, listenedAtSec: Long) {
        submit("single", artist, title, album, durationMs, positionMs = 0, listenedAt = listenedAtSec)
    }

    private suspend fun submit(
        type: String,
        artist: String,
        title: String,
        album: String?,
        durationMs: Long,
        positionMs: Long,
        listenedAt: Long?,
    ) {
        val token = AppSettings.listenBrainzToken.value
        if (token.isBlank()) return
        val durationPart = if (durationMs > 0) "\"duration_ms\":$durationMs," else ""
        val releasePart = if (album.isNullOrBlank()) "" else "\"release_name\":\"${esc(album)}\","
        val listened = if (listenedAt != null) "\"listened_at\":$listenedAt," else ""
        val track = """{$listened"track_metadata":{"artist_name":"${esc(artist)}","track_name":"${esc(title)}",$releasePart"additional_info":{${durationPart}"position_ms":$positionMs,"submission_client":"BitChord"}}}"""
        val body = """{"listen_type":"$type","payload":[$track]}"""
        runCatching {
            Http.postJson(
                API,
                body,
                headers = mapOf(
                    "Authorization" to "Token $token",
                    "Content-Type" to "application/json",
                ),
            )
        }
    }

    private fun esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")
}

package com.music.bitchord.data.scrobbling

import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.ExperimentalTime

@OptIn(ExperimentalTime::class)
object ScrobbleBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface AuthCallback {
        fun onResult(ok: Boolean, message: String?)
    }

    fun lastFmAuthUrl(callback: AuthCallback) {
        scope.launch {
            val token = LastFM.getToken()
            if (token == null) {
                callback.onResult(false, "Need a Last.fm API key and secret in Settings.")
            } else {
                callback.onResult(true, LastFM.authUrl(token) + "\n$token")
            }
        }
    }

    fun lastFmComplete(token: String, callback: AuthCallback) {
        scope.launch {
            val session = LastFM.getSession(token)
            if (session == null) {
                callback.onResult(false, "Last.fm didn't return a session. Authorise the token first.")
            } else {
                AppSettings.setLastFmUsername(session.first)
                AppSettings.setLastFmSession(session.second)
                callback.onResult(true, session.first)
            }
        }
    }

    fun nowPlaying(artist: String, title: String, album: String?, durationSec: Int, positionMs: Long) {
        scope.launch {
            if (AppSettings.lastFmEnabled.value && AppSettings.lastFmNowPlaying.value) {
                runCatching { LastFM.updateNowPlaying(artist, title, album, durationSec) }
            }
            if (AppSettings.listenBrainzEnabled.value) {
                runCatching { ListenBrainz.playingNow(artist, title, album, durationSec * 1000L, positionMs) }
            }
        }
    }

    fun scrobble(artist: String, title: String, album: String?, durationSec: Int) {
        scope.launch {
            val ts = Clock.System.now().toEpochMilliseconds() / 1000
            if (AppSettings.lastFmEnabled.value && AppSettings.lastFmScrobble.value) {
                runCatching { LastFM.scrobble(artist, title, album, ts, durationSec) }
            }
            if (AppSettings.listenBrainzEnabled.value) {
                runCatching { ListenBrainz.scrobble(artist, title, album, durationSec * 1000L, ts) }
            }
        }
    }
}

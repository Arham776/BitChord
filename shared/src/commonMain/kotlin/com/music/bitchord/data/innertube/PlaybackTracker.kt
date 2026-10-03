package com.music.bitchord.data.innertube

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Reports actual starts, watch time and completed/repeated plays to the signed-in
 * YouTube account. Stream resolution can use another audio source; the history
 * still belongs to the YouTube song the listener selected.
 */
object PlaybackTracker {
    private val VIDEO_ID = Regex("""[A-Za-z0-9_-]{11}""")
    private data class Session(
        val generation: Long,
        val cpn: String,
        val tracking: Innertube.PlaybackTracking,
    )
    private val reporter = PlaybackHistoryReporter(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
        generation = { Innertube.sessionGeneration },
        open = { videoId, generation ->
            Innertube.checkSession(generation)
            val timestamp = CipherUnlock.signatureTimestamp()
            Innertube.checkSession(generation)
            val tracking = timestamp?.let { Innertube.playbackTracking(videoId, it) }
            if (tracking == null) null
            else {
                val session = Session(generation, Innertube.newCpn(), tracking)
                Innertube.pingPlayback(tracking.playbackUrl, session.cpn, generation)
                Innertube.checkSession(generation)
                session
            }
        },
        watchtime = { session, seconds, final ->
            session.tracking.watchtimeUrl?.let {
                Innertube.pingWatchtime(it, session.cpn, seconds, final, session.generation)
            }
            Unit
        },
        atr = { session ->
            session.tracking.atrUrl?.let { Innertube.pingAtr(it, session.cpn, session.generation) }
            Unit
        },
        atrAfter = { it.tracking.atrAfterSeconds },
    )

    fun onSessionChanged() = reporter.onSessionChanged()
    fun onPlaying(videoId: String) {
        if (VIDEO_ID.matches(videoId) && Innertube.cookie != null) reporter.onPlaying(videoId)
    }
    fun onTrackChanged(positionSeconds: Long) = reporter.onStopped(positionSeconds)
    fun onProgress(videoId: String, positionSeconds: Long) {
        if (VIDEO_ID.matches(videoId) && Innertube.cookie != null) reporter.onProgress(videoId, positionSeconds)
    }
    fun onPlaybackFinished(positionSeconds: Long) = reporter.onStopped(positionSeconds)
}

package com.music.bitchord.data.innertube

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.concurrent.Volatile

/**
 * Registers plays against the signed-in account's YouTube Music history so
 * Home recommendations reflect what was actually listened to.
 *
 * Compact port of upstream `PlaybackTracker`: videostatsPlaybackUrl on start,
 * atr a few seconds in, videostatsWatchtimeUrl as it plays and on close.
 */
object PlaybackTracker {

    private const val REPORT_INTERVAL_SECONDS = 30L
    private const val OPEN_ATTEMPTS = 3
    private const val OPEN_RETRY_DELAY_MS = 2_000L
    private val VIDEO_ID = Regex("""[A-Za-z0-9_-]{11}""")

    private class Session(
        val videoId: String,
        val generation: Long,
        val cpn: String,
        val tracking: Innertube.PlaybackTracking,
    ) {
        var reportedSeconds = 0L
        var flushingTo = 0L
        var atrSent = false
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = Mutex()

    @Volatile
    private var session: Session? = null

    @Volatile
    private var opening: String? = null

    fun onSessionChanged() {
        opening = null
        session = null // Never flush an old tracking URL under the next account.
    }

    fun onPlaying(videoId: String) {
        if (!VIDEO_ID.matches(videoId)) return
        if (Innertube.cookie == null) return
        if (session?.videoId == videoId || opening == videoId) return
        opening = videoId
        val generation = Innertube.sessionGeneration
        scope.launch {
            try {
                openWithRetries(videoId, generation)
            } finally {
                if (opening == videoId && Innertube.sessionGeneration == generation) opening = null
            }
        }
    }

    fun onTrackChanged(positionSeconds: Long) {
        val closing = session ?: return
        session = null
        scope.launch {
            runCatching { flush(closing, positionSeconds, final = true) }
        }
    }

    fun onProgress(videoId: String, positionSeconds: Long) {
        val current = session ?: return
        if (current.videoId != videoId || current.generation != Innertube.sessionGeneration) return
        if (!current.atrSent && positionSeconds >= current.tracking.atrAfterSeconds) {
            current.atrSent = true
            val atrUrl = current.tracking.atrUrl
            if (atrUrl != null) {
                scope.launch {
                    runCatching { Innertube.pingAtr(atrUrl, current.cpn, current.generation) }
                }
            }
        }
        if (positionSeconds - maxOf(current.reportedSeconds, current.flushingTo) < REPORT_INTERVAL_SECONDS) {
            return
        }
        scope.launch {
            runCatching { flush(current, positionSeconds) }
        }
    }

    fun onPlaybackFinished(positionSeconds: Long) {
        val closing = session ?: return
        session = null
        scope.launch {
            withContext(NonCancellable) {
                runCatching { flush(closing, positionSeconds, final = true) }
            }
        }
    }

    private suspend fun openWithRetries(videoId: String, generation: Long) {
        repeat(OPEN_ATTEMPTS) { attempt ->
            if (opening != videoId || Innertube.sessionGeneration != generation) return
            val settled = try {
                open(videoId, generation)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                false
            }
            if (settled) return
            if (attempt < OPEN_ATTEMPTS - 1) delay(OPEN_RETRY_DELAY_MS)
        }
    }

    private suspend fun open(videoId: String, generation: Long): Boolean = lock.withLock {
        Innertube.checkSession(generation)
        val signatureTimestamp = CipherUnlock.signatureTimestamp()
        if (signatureTimestamp == null) return@withLock false
        val tracking = Innertube.playbackTracking(videoId, signatureTimestamp)
            ?: return@withLock false
        Innertube.checkSession(generation)
        val fresh = Session(videoId, generation, Innertube.newCpn(), tracking)
        Innertube.pingPlayback(tracking.playbackUrl, fresh.cpn, generation)
        Innertube.checkSession(generation)
        session = fresh
        true
    }

    private suspend fun flush(target: Session, positionSeconds: Long, final: Boolean = false) {
        val url = target.tracking.watchtimeUrl ?: return
        if (!final && positionSeconds <= target.reportedSeconds) return
        target.flushingTo = maxOf(target.flushingTo, positionSeconds)
        lock.withLock {
            Innertube.pingWatchtime(url, target.cpn, positionSeconds, final, target.generation)
            target.reportedSeconds = maxOf(target.reportedSeconds, positionSeconds)
        }
    }
}

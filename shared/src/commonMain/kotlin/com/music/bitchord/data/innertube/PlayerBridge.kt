package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.AtomicLong
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Swift-facing seam over [StreamResolver].
 *
 * Thin on purpose. The resolution *policy* — which clients to ask, what to
 * remember between attempts, when to stand an identity down, and the signed-in
 * retries that are the difference between a bot check and a playable track —
 * lives in [StreamResolver], which mirrors upstream's own split between the
 * resolver and the FFI-shaped callers. This used to *be* the resolver, and being
 * both is how it ended up with no memory between calls and a global mutex
 * serialising every stream in the app.
 */
@OptIn(ExperimentalAtomicApi::class)
object PlayerBridge {
    private val ids = AtomicLong(0)
    private val jobs = AtomicReference<Map<Long, Job>>(emptyMap())
    private fun updateJobs(change: (Map<Long, Job>) -> Map<Long, Job>) {
        while (true) { val old = jobs.load(); if (jobs.compareAndSet(old, change(old))) return }
    }
    fun cancelResolve(requestId: Long) { jobs.load()[requestId]?.cancel() }

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, callback: ResolveCallback) {
        resolve(videoId, Int.MAX_VALUE, callback)
    }

    fun resolve(videoId: String, maxKbps: Int, callback: ResolveCallback) {
        resolveRequest(videoId, maxKbps, callback)
    }

    /** Cancellable replacement; older one-result entry points remain available. */
    fun resolveRequest(videoId: String, maxKbps: Int, callback: ResolveCallback): Long {
        val id = ids.addAndFetch(1)
        val generation = Innertube.sessionGeneration
        val job = bridgeScope.launch(start = CoroutineStart.LAZY) {
            try {
                Innertube.checkSession(generation)
                val resolved = StreamResolver.resolve(videoId, maxKbps)
                    ?: throw IllegalStateException("No playable stream for $videoId")
                val payload = StreamPayload(
                    url = resolved.url,
                    kbps = resolved.kbps,
                    mimeType = resolved.mimeType,
                    headers = resolved.headers,
                    loudnessDb = resolved.loudnessDb,
                    durationSeconds = resolved.durationSeconds,
                )
                Innertube.checkSession(generation)
                callback.onResult(json.encodeToString(StreamPayload.serializer(), payload), null)
            } catch (e: StreamResolver.PermanentlyUnplayableException) {
                // A verdict, not a failure. Carried in the message so the caller can
                // show it as a sentence rather than an error, which is the whole
                // reason it is its own type.
                callback.onResult(null, e.message ?: "This track cannot be played")
            } catch (e: Throwable) {
                DebugLog.e("resolve failed for $videoId", e)
                callback.onResult(null, e.message ?: e.toString())
            } finally { updateJobs { it - id } }
        }
        updateJobs { it + (id to job) }
        job.start()
        return id
    }

    /**
     * Feed a refusal observed on the *playback* path back into the resolver.
     *
     * The probe runs before playback and not again, so nothing else would ever find
     * out that a URL which served bytes once has stopped. Without this the client
     * stays preferred and the URL stays cached, and every following track fails the
     * same way until the app is restarted.
     */
    fun onPlaybackRefused(url: String, responseCode: Int) {
        StreamResolver.onPlaybackRefused(url, responseCode)
    }

    @Serializable
    data class StreamPayload(
        val url: String,
        val kbps: Int,
        val mimeType: String,
        val headers: Map<String, String> = emptyMap(),
        /** Absent (null) on payloads minted before the figure was parsed. */
        val loudnessDb: Double? = null,
        val durationSeconds: Long? = null,
    )
}

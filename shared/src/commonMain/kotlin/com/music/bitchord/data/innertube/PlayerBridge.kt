package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
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
object PlayerBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, callback: ResolveCallback) {
        resolve(videoId, Int.MAX_VALUE, callback)
    }

    fun resolve(videoId: String, maxKbps: Int, callback: ResolveCallback) {
        bridgeScope.launch {
            try {
                val resolved = StreamResolver.resolve(videoId, maxKbps)
                    ?: throw IllegalStateException("No playable stream for $videoId")
                val payload = StreamPayload(
                    url = resolved.url,
                    kbps = resolved.kbps,
                    mimeType = resolved.mimeType,
                    headers = resolved.headers,
                )
                callback.onResult(json.encodeToString(StreamPayload.serializer(), payload), null)
            } catch (e: StreamResolver.PermanentlyUnplayableException) {
                // A verdict, not a failure. Carried in the message so the caller can
                // show it as a sentence rather than an error, which is the whole
                // reason it is its own type.
                callback.onResult(null, e.message ?: "This track cannot be played")
            } catch (e: Throwable) {
                DebugLog.e("resolve failed for $videoId", e)
                callback.onResult(null, e.message ?: e.toString())
            }
        }
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
    )
}

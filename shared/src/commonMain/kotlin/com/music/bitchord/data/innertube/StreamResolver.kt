package com.music.bitchord.data.innertube
import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.ProbeResult
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.TimeMark
import kotlin.time.TimeSource
import kotlin.time.Duration.Companion.minutes

/** Maintained upstream extraction, with account-scoped coalescing and verified media URLs. */
object StreamResolver {
    data class ResolvedStream(val url: String, val kbps: Int, val mimeType: String,
                              val headers: Map<String, String>, val loudnessDb: Double? = null, val durationSeconds: Long? = null)
    class PermanentlyUnplayableException(reason: String) : Exception(reason)
    private class Resolved(val stream: ResolvedStream, val generation: Long, val at: TimeMark)
    private val recent = CowMap<String, Resolved>()
    private data class Flight(val job: Deferred<ResolvedStream>, val waiters: Int)
    private val inFlight = CowMap<String, Flight>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    internal var extraction: suspend (String, Int) -> ResolvedStream? = { id, ceiling -> UpstreamPlaybackExtractor.extract(id, ceiling) }
    internal var streamProbe: suspend (String, Map<String, String>) -> ProbeResult = { url, headers -> Http.probe(url, headers) }
    suspend fun resolve(videoId: String, maxKbps: Int = Int.MAX_VALUE): ResolvedStream? {
        val generation = Innertube.sessionGeneration
        val key = "$generation|$videoId|$maxKbps"
        recent.snapshot()[key]?.takeIf { it.at.elapsedNow() < 20.minutes }?.let { return it.stream }
        val candidate = scope.async(start = CoroutineStart.LAZY) {
            repeat(3) { attempt ->
                Innertube.checkSession(generation)
                val stream = extraction(videoId, maxKbps) ?: error("No playable stream for $videoId")
                Innertube.checkSession(generation)
                val proof = streamProbe(stream.url, stream.headers)
                Innertube.checkSession(generation)
                if (proof.classify(stream.mimeType) == ProbeVerdict.OK) return@async stream
                // A URL may be refused transiently even though its profile
                // works. Remint once with a fresh nonce before excluding that
                // profile and taking upstream's alternate-client path.
                if (attempt > 0) {
                    onPlaybackRefused(stream.url, proof.status)
                    UpstreamPlaybackExtractor.onRefused(stream.url, excludeClient = true)
                }
                if (attempt == 2) error("Upstream media refused (HTTP ${proof.status})")
                DebugLog.w("$videoId: issued URL failed media validation; requesting a fresh extraction")
            }
            error("No playable stream for $videoId")
        }
        var selected = candidate
        inFlight.update { map ->
            val existing = map[key]
            if (existing == null) { selected = candidate; map[key] = Flight(candidate, 1) }
            else { selected = existing.job; map[key] = existing.copy(waiters = existing.waiters + 1) }
        }
        if (selected !== candidate) candidate.cancel()
        selected.start()
        try {
            val stream = selected.await()
            Innertube.checkSession(generation)
            recent.update { map ->
                if (map.size >= 32) map.clear()
                map[key] = Resolved(stream, generation, TimeSource.Monotonic.markNow())
            }
            return stream
        } finally {
            var abandoned: Deferred<ResolvedStream>? = null
            inFlight.update { map ->
                val flight = map[key]
                if (flight?.job === selected) {
                    if (flight.waiters <= 1) { map.remove(key); abandoned = flight.job }
                    else { map[key] = flight.copy(waiters = flight.waiters - 1); abandoned = null }
                }
            }
            abandoned?.cancel()
        }
    }
    fun onSessionChanged() {
        inFlight.snapshot().values.forEach { it.job.cancel() }; inFlight.clear(); recent.clear()
        DebugLog.d("session changed; cleared upstream resolver flights and media URLs")
    }
    fun onPlaybackRefused(url: String, responseCode: Int) {
        if (responseCode !in setOf(403, 404, 410)) return
        recent.update { map -> map.entries.removeAll { it.value.stream.url == url } }
        UpstreamPlaybackExtractor.onRefused(url)
        DebugLog.w("served media URL refused; next resolution will use fresh upstream extraction")
    }
    internal class AudioFormat(
        val url: String?,
        val signatureCipher: String?,
        val mimeType: String,
        val kbps: Int,
    )

    /** Playable renditions within the selected data budget, ranked by codec tier.
     * Broken cipher solving makes unciphered formats preferable within that
     * budget; it never authorizes silently downloading an over-budget stream.
     */
    internal fun rankForPlayback(response: JsonObject, maxKbps: Int, signatureBroken: Boolean = SignatureSolver.isBroken): List<AudioFormat> {
        val within = audioFormats(response).filter {
            (it.kbps > 0 && it.kbps <= maxKbps) || (it.kbps == 0 && maxKbps == Int.MAX_VALUE)
        }
        val uncipheredFirst = compareByDescending<AudioFormat> { it.url != null }
        val fidelity = compareByDescending<AudioFormat> {
            if (it.mimeType.contains("opus", ignoreCase = true) && it.kbps >= 128) 2
            else if (it.kbps >= 192) 2 else if (it.kbps >= 96) 1 else 0
        }.thenByDescending { it.mimeType.contains("opus", ignoreCase = true) }
            .thenByDescending { it.kbps }.then(uncipheredFirst)
        return within.sortedWith(if (signatureBroken) uncipheredFirst.then(fidelity) else fidelity)
    }

    private fun audioFormats(response: JsonObject): List<AudioFormat> {
        val streamingData = response["streamingData"] as? JsonObject ?: return emptyList()
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return (adaptive + legacy).filterIsInstance<JsonObject>().mapNotNull { it.toAudioFormat() }
    }

    /**
     * How many formats the response held, playable or not.
     *
     * For the line that says what a client did *not* give us. Counting the audio
     * entries here would make the number agree with the filter and say nothing; the
     * useful number is what arrived.
     */
    private fun countFormats(response: JsonObject): Int {
        val streamingData = response["streamingData"] as? JsonObject ?: return 0
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return adaptive.size + legacy.size
    }

    /**
     * Audio-only, or muxed MP4 that still carries AAC — the remaining guest format
     * when adaptive audio is SABR-only.
     */
    private fun JsonObject.toAudioFormat(): AudioFormat? {
        val mime = (get("mimeType") as? JsonPrimitive)?.contentOrNull ?: return null
        val audioOnly = mime.startsWith("audio/")
        val muxedAac = mime.startsWith("video/mp4") && mime.contains("mp4a", ignoreCase = true)
        if (!audioOnly && !muxedAac) return null
        // AAC and Opus are both supported by the Apple native decoder.
        val url = (get("url") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        val cipher = (get("signatureCipher") as? JsonPrimitive)?.contentOrNull
            ?: (get("cipher") as? JsonPrimitive)?.contentOrNull
        if (url == null && cipher == null) return null
        val bps = (get("bitrate") as? JsonPrimitive)?.intOrNull ?: 0
        return AudioFormat(url, cipher, mime, (bps / 1000).coerceAtLeast(0))
    }

}

@OptIn(ExperimentalAtomicApi::class)
private class CowMap<K : Any, V : Any> {

    private val ref = AtomicReference<Map<K, V>>(emptyMap())

    fun snapshot(): Map<K, V> = ref.load()

    fun update(block: (MutableMap<K, V>) -> Unit) {
        while (true) {
            val current = ref.load()
            val next = LinkedHashMap(current)
            block(next)
            if (ref.compareAndSet(current, next)) return
        }
    }

    fun clear() {
        ref.store(emptyMap())
    }
}

package com.music.bitchord.data.sources

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Swift-facing seam over [SourceResolver].
 *
 * Deliberately shaped around the four decisions the host actually has to make at
 * a moment of playback, rather than exposing the resolver's internals:
 *
 *  - [canSubstituteForYouTube] — cheap, synchronous, and asked from the cache and
 *    the read-ahead *before* anyone has searched, so it has to be answerable from
 *    the source list alone.
 *  - [substituteForYouTube] — the latency-critical race, run before a queued YouTube
 *    track is resolved.
 *  - [prefetchSubstitute] — the same race, earlier, narrowed to the sources quick
 *    enough to be worth asking speculatively.
 *  - [upgradeFor] — the unhurried second look, run with sound already playing.
 *  - [forDownload] — the one whose answer becomes a file rather than a stream.
 *
 * [worthSwapping] and [sameRecordingAs] are exposed because the host has to apply
 * the *same* judgements when it adopts or refuses a swap. They used to be
 * reimplemented in Swift, which is how the two copies came to disagree: the
 * Swift one had no Dolby-Atmos rule and its `canSubstitute` merely checked whether
 * any source URL was configured, so a source ranked *last* counted as a reason to
 * substitute.
 */
object SourceResolverBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface StreamCallback {
        fun onResult(json: String?, message: String?)
    }

    fun interface AnswerCallback {
        fun onResult(answer: Boolean)
    }

    // ── Cheap, synchronous ────────────────────────────────────────────��─────

    /**
     * Whether anything outranks YouTube.
     *
     * The real check — the ranked list, not "is a URL configured". The old Swift
     * version returned true if *any* source was set at all, including one ranked
     * below YouTube, so every queued track paid a pointless race for a source that
     * could not have won it.
     */
    fun canSubstituteForYouTube(): Boolean = SourceResolver.canSubstituteForYouTube()

    /** A stream that genuinely satisfies the request, for a track already playing. */
    fun worthSwapping(candidateJson: String, playingJson: String?): Boolean {
        val candidate = readFormat(candidateJson) ?: return false
        val playing = playingJson?.let { readFormat(it) }
        return SourceResolver.worthSwapping(candidate, playing)
    }

    /** Whether two runtimes are close enough to be the same recording. */
    fun sameRecordingAs(candidateSec: Int?, playingSec: Int?): Boolean =
        SourceResolver.sameRecordingAs(candidateSec, playingSec)

    // ── The races ───────────────────────────────────────────────────────────

    /** The stream for a queued YouTube track from a source ranked above it. */
    fun substituteForYouTube(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String?,
        isExplicit: Boolean?,
        isVideo: Boolean,
        callback: StreamCallback,
    ) = launch(callback) {
        val target = TrackMatcher.Target(title, artist, durationSec, album, isExplicit, isVideo)
        SourceResolver.substituteForYouTube(target)?.let { callback.onResult(it.encode(), null) }
            ?: callback.onResult(null, null)
    }

    /**
     * The unhurried second look for a track already playing.
     *
     * @param playingJson what the listener is hearing now, as a
     *   [StreamFormat] document or null when unmeasured. A null floor is treated as
     *   one nothing lossy clears: a swap that might be a downgrade is worse than no
     *   swap at all.
     * @param servedBy the config id already serving the track, so it is not asked
     *   again for a stream it would only reproduce.
     */
    fun upgradeFor(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String?,
        isExplicit: Boolean?,
        isVideo: Boolean,
        playingJson: String?,
        servedBy: String?,
        callback: StreamCallback,
    ) = launch(callback) {
        val target = TrackMatcher.Target(title, artist, durationSec, album, isExplicit, isVideo)
        val playing = playingJson?.let { readFormat(it) }
        SourceResolver.upgradeFor(target, playing, servedBy)
            ?.let { callback.onResult(it.encode(), null) }
            ?: callback.onResult(null, null)
    }

    /**
     * The copy a source quick enough to ask about *before* the track is played.
     *
     * The caller is expected to **pin** a returned stream before caching any of it,
     * or playback re-runs the race and may land on a different source — writing a
     * second file into the cache entry the warm one already half-filled.
     */
    fun prefetchSubstitute(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String?,
        isExplicit: Boolean?,
        isVideo: Boolean,
        callback: StreamCallback,
    ) = launch(callback) {
        val target = TrackMatcher.Target(title, artist, durationSec, album, isExplicit, isVideo)
        SourceResolver.prefetchSubstitute(target)?.let { callback.onResult(it.encode(), null) }
            ?: callback.onResult(null, null)
    }

    /** The copy worth keeping as a file over whatever YouTube's ladder would give. */
    fun forDownload(
        title: String,
        artist: String,
        durationSec: Int?,
        album: String?,
        isExplicit: Boolean?,
        isVideo: Boolean,
        quality: String,
        callback: StreamCallback,
    ) = launch(callback) {
        val target = TrackMatcher.Target(title, artist, durationSec, album, isExplicit, isVideo)
        val request = SourceResolver.requestForDownload(
            com.music.bitchord.data.settings.DownloadQuality.fromName(quality),
        )
        SourceResolver.forDownload(target, request)?.let { callback.onResult(it.encode(), null) }
            ?: callback.onResult(null, null)
    }

    // ── Registry, for the sources screen ────────────────────────────────────

    fun interface ConfigsCallback {
        fun onResult(json: String?)
    }

    fun interface HealthCallback {
        fun onResult(configId: String, health: String, detail: String)
    }

    fun interface ActionCallback {
        fun onResult(ok: Boolean, message: String?)
    }

    /** Every configured source, as a document the sources screen can read. */
    fun configs(callback: ConfigsCallback) {
        callback.onResult(json.encodeToString(ConfigListing.serializer(), readConfigs()))
    }

    /** Reachability for one configured source, or for a candidate not yet saved. */
    fun health(configId: String, callback: HealthCallback) {
        scope.launch {
            val config = SourceRegistry.config(configId)
            val health = if (config != null) {
                SourceRegistry.probeCandidate(config)
            } else {
                com.music.bitchord.data.sources.SourceHealth.Rejected("Unknown source")
            }
            callback.onResult(configId, healthName(health), healthDetail(health))
        }
    }

    /** Health for a config that has not been saved — the editor's Test button. */
    fun probeCandidate(config: SourceConfig, callback: HealthCallback) {
        scope.launch {
            val health = SourceRegistry.probeCandidate(config)
            callback.onResult(config.id, healthName(health), healthDetail(health))
        }
    }

    /**
     * Save a source: add it when the id is new, update it otherwise.
     *
     * The URL goes to the secret tier rather than the settings list, so an addon
     * whose address carries a token does not end up in a preferences dump.
     */
    fun save(config: SourceConfig, callback: ActionCallback) {
        scope.launch {
            try {
                val existing = SourceRegistry.config(config.id)
                if (existing == null) {
                    SourceRegistry.add(config)
                } else {
                    SourceRegistry.update(config)
                }
                callback.onResult(true, null)
            } catch (e: Exception) {
                DebugLog.e("saving a source failed", e)
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }

    fun setEnabled(configId: String, enabled: Boolean, callback: ActionCallback) {
        SourceRegistry.setEnabled(configId, enabled)
        callback.onResult(true, null)
    }

    fun remove(configId: String, callback: ActionCallback) {
        SourceRegistry.remove(configId)
        callback.onResult(true, null)
    }

    /** Put the addons in the order the listener dragged them into. */
    fun reorderAddons(orderedIds: List<String>, callback: ActionCallback) {
        SourceRegistry.reorderAddons(orderedIds)
        callback.onResult(true, null)
    }

    /**
     * Whether [url] is already configured, so the editor can refuse a second copy.
     *
     * Compared after normalisation, which is what makes it catch the cases worth
     * catching: a trailing slash, a `MANIFEST.JSON`, and a differently-cased host
     * are all the same source.
     */
    fun isDuplicate(url: String, exceptId: String?): Boolean =
        SourceRegistry.duplicateOf(url, exceptId) != null

    /** The one place a quality decision is made, exposed so the host agrees with it. */
    private fun launch(callback: StreamCallback, block: suspend () -> Unit) {
        scope.launch {
            try {
                block()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                DebugLog.e("source resolution failed", e)
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    // ── Wire format ─────────────────────────────────────────────────────────

    private fun healthName(health: com.music.bitchord.data.sources.SourceHealth): String =
        when (health) {
            is com.music.bitchord.data.sources.SourceHealth.Ok -> "ok"
            is com.music.bitchord.data.sources.SourceHealth.Unreachable -> "unreachable"
            is com.music.bitchord.data.sources.SourceHealth.Rejected -> "rejected"
        }

    private fun healthDetail(health: com.music.bitchord.data.sources.SourceHealth): String =
        when (health) {
            is com.music.bitchord.data.sources.SourceHealth.Ok -> health.detail.orEmpty()
            is com.music.bitchord.data.sources.SourceHealth.Unreachable -> health.reason
            is com.music.bitchord.data.sources.SourceHealth.Rejected -> health.reason
        }

    private fun readFormat(document: String): StreamFormat? =
        runCatching { json.decodeFromString(FormatDocument.serializer(), document) }
            .getOrNull()
            ?.toFormat()

    private fun StreamFormat.encode(): String =
        json.encodeToString(
            FormatDocument.serializer(),
            FormatDocument(
                codec = codec,
                kbps = kbps,
                sampleRateHz = sampleRateHz,
                bitDepth = bitDepth,
                isLossless = isLossless,
                isDolbyAtmos = isDolbyAtmos,
                summary = summary,
            ),
        )

    private fun readConfigs(): ConfigListing = ConfigListing(
            SourceRegistry.configs.value.map { config ->
                ConfigDocument(
                    id = config.id,
                    kind = config.kind.name,
                    label = config.label,
                    displayName = config.displayName,
                    // The real address comes from the secret tier; `SourceConfig`'s own
                    // field is a fallback for a config stored before the split.
                    baseUrl = SourceRegistry.baseUrlOf(config),
                    enabled = config.enabled,
                    isComplete = config.isComplete,
                    needsServer = config.kind.needsServer,
                    canServeLossless = config.kind.canServeLossless,
                    labels = config.kind.labels,
                )
            },
        )
}

/**
 * The wire format between the source layer and the host.
 *
 * `isLossless` is carried as a real nullable rather than a defaulted `false`,
 * because "unknown" is a different answer from "no" and the host needs both: it
 * decides whether a swap is worth making, and a source that declined to describe
 * its stream must not read as having said it is lossy.
 */
@Serializable
data class FormatDocument(
    val codec: String? = null,
    val kbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
    val isLossless: Boolean? = null,
    val isDolbyAtmos: Boolean = false,
    val summary: String = "",
)

/** A [SourceStream] as the host receives it. */
@Serializable
data class StreamDocument(
    val url: String,
    val format: FormatDocument,
    val headers: Map<String, String> = emptyMap(),
    val belowRequest: Boolean = false,
    val durationSec: Int? = null,
    val sourceConfigId: String? = null,
)

/** One configured source, for the sources screen. */
@Serializable
data class ConfigDocument(
    val id: String,
    val kind: String,
    val label: String,
    val displayName: String,
    val baseUrl: String,
    val enabled: Boolean,
    val isComplete: Boolean,
    val needsServer: Boolean,
    val canServeLossless: Boolean,
    val labels: List<String>,
)

@Serializable
data class ConfigListing(val sources: List<ConfigDocument>)

private fun FormatDocument.toFormat(): StreamFormat = StreamFormat(
    codec = codec,
    kbps = kbps,
    sampleRateHz = sampleRateHz,
    bitDepth = bitDepth,
)

private val wireJson = Json { ignoreUnknownKeys = true }

private fun StreamFormat.encode(): String = wireJson.encodeToString(
    FormatDocument.serializer(),
    FormatDocument(
        codec = codec,
        kbps = kbps,
        sampleRateHz = sampleRateHz,
        bitDepth = bitDepth,
        isLossless = isLossless,
        isDolbyAtmos = isDolbyAtmos,
        summary = summary,
    ),
)

private fun SourceStream.encode(): String = wireJson.encodeToString(
    StreamDocument.serializer(),
    StreamDocument(
        url = url,
        format = FormatDocument(
            codec = format.codec,
            kbps = format.kbps,
            sampleRateHz = format.sampleRateHz,
            bitDepth = format.bitDepth,
            isLossless = format.isLossless,
            isDolbyAtmos = format.isDolbyAtmos,
            summary = format.summary,
        ),
        headers = headers,
        belowRequest = belowRequest,
        durationSec = durationSec,
        sourceConfigId = sourceConfigId,
    ),
)

package com.music.bitchord.data.sources

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.concurrent.Volatile
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Port of upstream `data/sources/ModuleSource.kt` — a module index, expressed
 * through [MusicSource].
 *
 * ## Why this is still a source kind
 *
 * The module protocol is the *legacy* one: a JSON index listing JS plugin
 * descriptors, each shipping a JavaScript file that exports `searchTracks()` and
 * `getTrackStreamUrl()`. [SourceKind.ADDON] exists to replace it, and an index
 * configured by an earlier build keeps working through this.
 *
 * The JS runs in a JavaScriptCore sandbox on Apple — there is no QuickJS here, and
 * the difference matters only in that the engine is Apple's rather than a
 * vendored one. Everything above the engine is portable and lives in this file:
 * fetching the index, loading each plugin, and fanning the fan-out out.
 *
 * ## Why it is a separate kind from [SourceKind.CUSTOM_MODULE] despite sharing
 * this implementation
 *
 * Only its rank differs. Two kinds sharing a position would have made the
 * user-dragged order between them unexpressible, and the kinds are separate
 * because one is offered by the sources screen and the other is not.
 */
class ModuleSource(override val config: SourceConfig) : MusicSource, ConfigBacked {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    @Volatile
    private var index: List<ModuleEntry> = emptyList()

    @Volatile
    private var indexFetchedAt: TimeMark? = null

    override val configId: String get() = config.id
    override val kind: SourceKind get() = config.kind
    override val displayName: String get() = config.displayName

    /**
     * The index, fetched at most once per [INDEX_TTL].
     *
     * Cached because it is the cheap half of this protocol: one document that
     * changes almost never, against `searchTracks` and `getTrackStreamUrl` which
     * are live calls into somebody else's backend. Measured upstream, walking an
     * index's backends takes 7-13s, which is why [SourceKind.worthPrefetching] is
     * false for this kind — but the index itself is worth keeping.
     */
    private suspend fun entries(): List<ModuleEntry> {
        val url = SourceRegistry.baseUrlOf(config)
        if (url.isBlank()) return emptyList()
        val fetchedAt = indexFetchedAt
        if (index.isNotEmpty() && fetchedAt != null && fetchedAt.elapsedNow() < INDEX_TTL) {
            return index
        }
        val body = runCatching { Http.getText(url, timeoutMillis = 15_000) }
            .onFailure { DebugLog.w("module index unreachable: ${it.message}") }
            .getOrNull() ?: return index
        val parsed = parseIndex(body)
        if (parsed.isNotEmpty()) {
            index = parsed
            indexFetchedAt = TimeSource.Monotonic.markNow()
        }
        return index
    }

    /**
     * The index reachable, and whether anything in it can actually search and
     * stream.
     *
     * An index whose entries all lack the two functions is a configuration error
     * rather than an outage, and saying so is the difference between a user fixing
     * a URL and a user waiting for a server that was never going to answer.
     */
    override suspend fun health(): SourceHealth {
        val url = SourceRegistry.baseUrlOf(config)
        if (url.isBlank()) return SourceHealth.Rejected("No module index configured")
        val found = runCatching { entries() }
            .getOrElse { failure ->
                return SourceHealth.Unreachable(failure.message ?: "Index unreachable")
            }
        if (found.isEmpty()) return SourceHealth.Unreachable("Index listed no modules")
        val usable = found.count { it.download.isNotBlank() }
        if (usable == 0) return SourceHealth.Rejected("No module here ships an executable script")
        return SourceHealth.Ok("${found.size} module(s) · $usable executable")
    }

    /**
     * Every module in the index, at once.
     *
     * [waitForAll] is upstream's distinction and it is the right one: a fan-out
     * that cancels its stragglers is right while someone is staring at a paused
     * player, where a straggler costs more than the rows it would have added, and
     * wrong for the background pass that runs *during* playback and can afford the
     * slow catalogue that turns out to be the one holding the FLAC.
     *
     * The requests are issued on a scope that outlives this call — see
     * [com.music.bitchord.data.sources.module.SharedCalls] for why — so a cancelled
     * caller drops its await and nothing else.
     */
    override suspend fun search(
        query: String,
        limit: Int,
        waitForAll: Boolean,
        request: StreamRequest?,
    ): List<Song> {
        val found = entries()
        if (found.isEmpty()) return emptyList()
        val results = coroutineScope {
            found
                .filter { it.download.isNotBlank() }
                .map { entry ->
                    async {
                        runCatching { ModuleEngine.search(entry, query, request?.tier) }
                            .onFailure { if (it !is CancellationException) {
                                DebugLog.d("${entry.name}: search failed (${it.message})")
                            } }
                            .getOrDefault(emptyList())
                    }
                }
                .awaitAll()
        }
        val rows = results.flatten()
        if (rows.isEmpty()) return emptyList()
        return rows
            .sortedByDescending { it.rank(request) }
            .take(limit)
            .map { it.toSong(config.id) }
    }

    override suspend fun stream(trackId: String, request: StreamRequest): SourceStream? {
        // A track id packed by [SourceRegistry] names the module that issued it;
        // an unpacked one is an ordinary YouTube id, which is not this source's.
        val (ownerId, moduleTrackId) = SourceRegistry.parseTrackKey(trackId)
            ?: return null
        if (ownerId != config.id) return null
        val entry = entries().firstOrNull { it.id in moduleTrackId || moduleTrackId.startsWith(it.id) }
            ?: return null
        val answer = runCatching { ModuleEngine.stream(entry, moduleTrackId, request.tier) }
            .onFailure { DebugLog.d("${entry.name}: stream failed (${it.message})") }
            .getOrNull() ?: return null
        if (answer.url.isBlank()) return null
        return SourceStream(
            url = answer.url,
            format = answer.toFormat(),
            headers = answer.headers,
            belowRequest = answer.belowRequest,
            durationSec = answer.durationSec,
            sourceConfigId = config.id,
        )
    }

    /** Everything held, dropped — see [AddonSource.release]. */
    fun release() {
        index = emptyList()
        indexFetchedAt = null
        ModuleEngine.forget(config.id)
    }

    /**
     * The index is a JSON document whose exact shape has varied between issuers, so
     * it is sniffed rather than decoded: any array of objects carrying an `id` and
     * a `download` is an entry list, wherever in the document it sits.
     */
    private fun parseIndex(body: String): List<ModuleEntry> {
        val root = runCatching { json.parseToJsonElement(body) }.getOrNull() ?: return emptyList()
        val arrays = mutableListOf<JsonArray>()
        when (root) {
            is JsonArray -> arrays += root
            is JsonObject -> {
                root.values.filterIsInstance<JsonArray>().forEach { arrays += it }
                root.values.filterIsInstance<JsonObject>().forEach { nested ->
                    nested.values.filterIsInstance<JsonArray>().forEach { arrays += it }
                }
            }
            else -> Unit
        }
        return arrays.asSequence()
            .flatMap { it.asSequence() }
            .filterIsInstance<JsonObject>()
            .mapNotNull { obj ->
                val id = obj["id"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                val tags = (obj["tags"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty() +
                    (obj["labels"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
                ModuleEntry(
                    id = id,
                    name = obj["name"]?.jsonPrimitive?.contentOrNull ?: id,
                    author = obj["author"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    version = obj["version"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    download = obj["download"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    lossless = tags.any {
                        it.contains("LOSSLESS", true) || it.contains("FLAC", true) ||
                            it.contains("HI-RES", true)
                    },
                )
            }
            .distinctBy { it.id }
            .toList()
    }

    private companion object {
        val INDEX_TTL = 30.minutes
    }
}

/** One entry from a module index. */
internal data class ModuleEntry(
    val id: String,
    val name: String,
    val author: String,
    val version: String,
    val download: String,
    val lossless: Boolean,
)

/** What a module answered a search with, before it becomes a [Song]. */
@Serializable
internal data class ModuleRow(
    val id: String = "",
    val title: String = "",
    val artist: String = "",
    val album: String? = null,
    val durationSec: Int? = null,
    val artworkUrl: String? = null,
    val codec: String? = null,
    val kbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
    val explicit: Boolean = false,
    val lossless: Boolean = false,
) {
    fun rank(request: StreamRequest?): Int {
        val losslessRow = lossless || codec?.lowercase() in LOSSY_FREE
        return when {
            request is StreamRequest.Lossless -> if (losslessRow) 10_000 else kbps ?: 0
            losslessRow && request !is StreamRequest.Capped -> 10_000 + (kbps ?: 0)
            else -> kbps ?: 0
        }
    }

    fun toSong(configId: String): Song = Song(
        videoId = SourceRegistry.trackKey(configId, id),
        title = title,
        artist = artist,
        thumbnailUrl = artworkUrl,
        durationText = mmss(durationSec),
        albumName = album,
        sourceQuality = codec?.uppercase() ?: if (lossless) "LOSSLESS" else null,
    )

    private companion object {
        val LOSSY_FREE = setOf("flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff")
    }
}

/** What a module answered a stream request with. */
@Serializable
internal data class ModuleStream(
    val url: String = "",
    val codec: String? = null,
    val kbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
    val belowRequest: Boolean = false,
    val durationSec: Int? = null,
) {
    fun toFormat(): StreamFormat = StreamFormat(
        codec = codec,
        kbps = kbps,
        sampleRateHz = sampleRateHz,
        bitDepth = bitDepth,
    )
}

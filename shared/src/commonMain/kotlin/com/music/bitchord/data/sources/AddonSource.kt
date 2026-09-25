package com.music.bitchord.data.sources

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.model.Song
import com.music.bitchord.data.sources.addon.AddonClient
import com.music.bitchord.data.sources.addon.AddonNotFound
import com.music.bitchord.data.sources.addon.AddonStream
import com.music.bitchord.data.sources.addon.AddonTrack
import com.music.bitchord.data.sources.addon.AddonUnavailable

/**
 * Port of upstream `data/sources/AddonSource.kt` — an addon server, expressed
 * through [MusicSource] so it can be ranked against every other source.
 *
 * The port had no equivalent at all: a "custom source" was an untyped URL whose
 * one invented response shape was parsed by string-guessing, with no health
 * model, no tier negotiation and no back-pressure handling. This is the protocol
 * as specified, which is a small amount of code precisely because the server does
 * the work.
 */
class AddonSource(override val config: SourceConfig) : MusicSource, ConfigBacked {

    private val client = AddonClient(SourceRegistry.baseUrlOf(config))

    override val configId: String get() = config.id
    override val kind: SourceKind get() = config.kind
    override val displayName: String get() = config.displayName

    /**
     * Reachability, credentials, and whether this thing can stream at all.
     *
     * The three answers are kept apart on purpose. [SourceHealth] exists to
     * distinguish "come back later" from "this will never work", and a sources
     * screen that collapses them sends people to re-paste a URL that was always
     * correct.
     */
    override suspend fun health(): SourceHealth {
        val manifest = client.manifest()
        manifest.exceptionOrNull()?.let { failure ->
            return when (failure) {
                // Momentarily down. Worth leaving enabled and asking again.
                is AddonUnavailable -> SourceHealth.Unreachable(failure.message ?: "Unavailable")
                else -> SourceHealth.Rejected(failure.message ?: "Not usable")
            }
        }
        // A manifest is a description, not proof the endpoints answer, and an
        // addon that never published one under a guessable name is still working.
        // So the search endpoint gets the second opinion before this is called Ok.
        return client.probeSearch().fold(
            onSuccess = { count ->
                val name = manifest.getOrNull()?.displayName ?: displayName
                SourceHealth.Ok(if (count > 0) "$name · $count rows" else "$name · reachable")
            },
            onFailure = { failure ->
                when (failure) {
                    is AddonUnavailable -> SourceHealth.Unreachable(failure.message ?: "Unavailable")
                    else -> SourceHealth.Rejected(failure.message ?: "Search endpoint did not answer")
                }
            },
        )
    }

    /**
     * Rows for [query], trimmed and ranked for what the caller intends to stream.
     *
     * An addon returns whatever it holds, so both the limit and the ranking are
     * this side's job. The ranking is by the row's own claims, read against the
     * [request] — a search made to find something to play at 128kbps should not be
     * answered with rows advertising 24/192 that the caller is never going to ask
     * for.
     */
    override suspend fun search(
        query: String,
        limit: Int,
        waitForAll: Boolean,
        request: StreamRequest?,
    ): List<Song> {
        val tier = request?.tier ?: AddonClient.TIER_HIGH
        val result = client.search(query, tier)
        result.exceptionOrNull()?.let { failure ->
            // A miss is not worth a line; anything else is, because this is the
            // only place that knows why an addon did not answer.
            if (failure !is AddonNotFound) {
                DebugLog.w("${config.displayName} search failed: ${failure.message}")
            }
            return emptyList()
        }
        return result.getOrDefault(emptyList())
            .asRows()
            .sortedByDescending { it.rank(request) }
            .take(limit)
            .map { it.toSong(config.id) }
    }

    override suspend fun stream(trackId: String, request: StreamRequest): SourceStream? {
        val result = client.stream(trackId, request.tier)
        result.exceptionOrNull()?.let { failure ->
            if (failure !is AddonNotFound) {
                DebugLog.w("${config.displayName} stream failed: ${failure.message}")
            }
            // A null return is a *miss*, not an error, and lets the resolver move
            // to the next source without recording a failure against this one.
            return null
        }
        val answer = result.getOrNull() ?: return null
        if (answer.url.isBlank()) return null
        return answer.toSourceStream(config.id, request)
    }

    /**
     * Everything held about this addon, dropped.
     *
     * Reached when the config is edited or removed, at which point the manifest and
     * every answer shaped by it describe a server that is no longer selected.
     */
    fun release() = client.clear()

    /** For the listener's explicit "Upgrade quality": ask again now, not from cache. */
    fun clearCompletedTrackCalls() = client.clearCompletedTrackCalls()
}

// ── Row mapping ────────────────────────────────────────────────────────

/**
 * One addon row, as this side sees it.
 *
 * A distinct type from [Song] because a row is not yet a track: it has no stable
 * identity until [SourceRegistry.trackKey] packs one, and it carries claims that
 * have not been checked. Mapping happens once, in [toSong], so there is exactly
 * one place where an addon's word becomes the app's data.
 */
internal data class AddonRow(
    val id: String,
    val title: String,
    val artist: String,
    val album: String?,
    val durationSec: Int?,
    val artworkUrl: String?,
    val codec: String?,
    val kbps: Int?,
    val sampleRateHz: Int?,
    val bitDepth: Int?,
    val explicit: Boolean,
    val lossless: Boolean,
) {
    /**
     * How good this row claims to be, for [StreamRequest]'s sake.
     *
     * Lossless first, then bitrate. Read from the row's own fields rather than
     * trusting its `lossless` flag alone: a row that sets the flag but names an mp3
     * codec is describing a transcode it has not performed, and ranking it as
     * bit-exact would put it above a real FLAC.
     */
    fun rank(request: StreamRequest?): Int {
        val losslessRow = lossless || codec?.lowercase() in LOSSLESS_CODECS
        return when {
            request is StreamRequest.Lossless -> if (losslessRow) 10_000 else kbps ?: 0
            losslessRow && request !is StreamRequest.Capped -> 10_000 + (kbps ?: 0)
            else -> kbps ?: 0
        }
    }

    fun toSong(configId: String): Song = Song(
        // The track's identity *is* its route back to this addon, packed into the
        // one field the whole app already treats as the media id.
        videoId = SourceRegistry.trackKey(configId, id),
        title = title,
        artist = artist,
        thumbnailUrl = artworkUrl,
        durationText = mmss(durationSec),
        albumName = album,
        sourceQuality = codec?.uppercase() ?: if (lossless) "LOSSLESS" else null,
    )

    private companion object {
        val LOSSLESS_CODECS = setOf("flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff")
    }
}

internal fun AddonTrack.asRow(): AddonRow = AddonRow(
    id = id,
    title = title,
    artist = artist,
    album = album,
    durationSec = durationSec,
    artworkUrl = artworkUrl,
    codec = codec,
    kbps = bitrateKbps,
    sampleRateHz = sampleRateHz,
    bitDepth = bitDepth,
    explicit = explicit,
    lossless = claimsLossless,
)

private fun List<AddonTrack>.asRows(): List<AddonRow> = map { it.asRow() }

/**
 * The stream an addon answered with, as this side's own type.
 *
 * [belowRequest] is the addon's claim about itself, overridden to true when the
 * app can see the answer was worse than what it asked for — an addon that says
 * nothing and quietly returned 128kbps to a lossless request is the case worth
 * catching, and the bitrate is right there.
 */
internal fun AddonStream.toSourceStream(
    configId: String,
    request: StreamRequest,
): SourceStream {
    val claimedCodec = codec?.lowercase()
    val claimedLossless = claimedCodec != null && claimedCodec in LOSSLESS_CODECS
    val servedKbps = bitrateKbps ?: 0
    val cap = request.kbpsCeiling
    val askedLossless = request is StreamRequest.Lossless
    val overCap = cap != null && servedKbps > cap
    return SourceStream(
        url = url,
        format = StreamFormat(
            codec = codec,
            kbps = bitrateKbps,
            sampleRateHz = sampleRateHz,
            bitDepth = bitDepth,
        ),
        headers = headers,
        belowRequest = belowRequest || (askedLossless && !claimedLossless) || overCap,
        durationSec = durationSec,
        sourceConfigId = configId,
    )
}

private val LOSSLESS_CODECS = setOf("flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff")

package com.music.bitchord.data.sources

import com.music.bitchord.data.model.Song

/**
 * Port of upstream `data/sources/MusicSource.kt` — the protocol every source
 * speaks, and the four types that describe a stream on its way to the decoder.
 *
 * Deliberately small, for upstream's reason: a source is asked to search its own
 * catalogue and to turn one of its own track ids into something openable. It is
 * not asked for home feeds, related tracks or radio — those stay with YouTube,
 * which is the only source that has them, and an interface wide enough to
 * express them would be one only a single implementation could ever satisfy.
 *
 * Before this the port had no protocol at all: one untyped "custom source URL"
 * string and one untyped "module index URL", both reimplemented ad-hoc in Swift.
 * Everything above them — quality upgrade, source substitution, download
 * routing, lossless detection — was therefore a reduced reimplementation with no
 * shared contract, and could not be made correct without one.
 */

/**
 * What a source is about to hand the decoder, as far as the source will say.
 *
 * Every field is nullable because most are genuinely unknown until the bytes
 * arrive: a server that reports "flac" rarely reports the bit depth with it, and
 * one that reports a bitrate is usually describing a transcode it has not
 * performed yet. Nothing here is inferred — null means "not stated", and the
 * player reports the decoder's own numbers over these once it has them. The two
 * are worth comparing rather than merging, because a source claiming 24/192 and
 * a sink running at 16/48 is exactly the failure this is most likely to hide.
 */
data class StreamFormat(
    /** Container/codec as the source names it, lowercased: `flac`, `opus`, `mp3`. */
    val codec: String? = null,
    val kbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
) {
    /**
     * Whether this is a bit-exact copy of the master the source holds.
     *
     * Decided on the codec alone. A lossless codec at any bitrate is lossless; a
     * lossy one at any bitrate is not, and no sample rate rescues it — a 192kHz
     * Opus stream is still Opus. An unknown codec means *unknown*, not false, so
     * callers that care have to say what they want done about it.
     */
    val isLossless: Boolean?
        get() = codec?.let { it.lowercase() in LOSSLESS_CODECS }

    /** Dolby Atmos carried in E-AC-3 JOC. Immersive, but not lossless. */
    val isDolbyAtmos: Boolean
        get() = codec?.lowercase() in DOLBY_ATMOS_CODECS

    /** "24-bit · 192 kHz", "FLAC", "320 kbps" — whichever parts are known. */
    val summary: String
        get() = if (isDolbyAtmos) {
            "Dolby Atmos"
        } else {
            listOfNotNull(
                codec?.uppercase(),
                bitDepth?.let { "$it-bit" },
                sampleRateHz?.let { "${khz(it)} kHz" },
                kbps?.takeIf { isLossless != true }?.let { "$it kbps" },
            ).joinToString(" · ").ifEmpty { "Unknown format" }
        }

    /**
     * 44100 → "44.1", 48000 → "48".
     *
     * Written out rather than reached for with a format string, because
     * `String.format` does not exist in common Kotlin — it is a JVM extension and
     * this module compiles for Kotlin/Native. The only kHz figures a source states
     * in practice are whole or one-decimal, so trimming a single trailing zero
     * covers them without dragging in a locale-aware formatter.
     */
    private fun khz(hz: Int): String {
        val tenths = hz / 100
        val whole = tenths / 10
        val fraction = tenths % 10
        return if (fraction == 0) "$whole" else "$whole.$fraction"
    }

    private companion object {
        val LOSSLESS_CODECS = setOf("flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff")
        val DOLBY_ATMOS_CODECS = setOf("eac3-joc", "ec3-joc", "dolby-atmos")
    }
}

/**
 * A URL the player can open, and what is expected to come back out of it.
 *
 * [headers] travel with the fetch because some sources bind the stream URL to
 * the request that asks for it. Sources that do not care leave it empty.
 */
data class SourceStream(
    val url: String,
    val format: StreamFormat = StreamFormat(),
    val headers: Map<String, String> = emptyMap(),
    /**
     * Whether this is less than was asked for, taken because nothing better
     * turned up in time.
     *
     * Playing it is the right call — a track that plays at 128kbps beats a track
     * that does not play — but it is worth knowing, because the reason is usually
     * a catalogue that was slow rather than one that was missing, and the same
     * question asked again during playback gets a better answer often enough to
     * be worth asking.
     */
    val belowRequest: Boolean = false,
    /**
     * How long the catalogue says this recording is, when it says.
     *
     * Carried so a stream found for a track that is *already playing* can be
     * checked against the length the decoder reports before it is cut in. The
     * match that produced this stream was made on a duration claimed by whoever
     * queued the track, which is not the same evidence: a 163s track was matched
     * to a 189s cut of the same song under the same title, and the only place
     * that was catchable before the audio broke was against the runtime actually
     * being played.
     */
    val durationSec: Int? = null,
    /**
     * Which [MusicSource.configId] this came from, when the caller knows.
     *
     * Set by [SourceResolver] once a source has actually answered — never by the
     * source itself, which has no reason to know its own id. Kept so a second
     * look during playback can leave the source already serving the track out
     * of the search: asking it again for the same recording at the same tier is
     * deterministic and only ever reproduces the stream already playing.
     */
    val sourceConfigId: String? = null,
)

/**
 * How much of the stream the caller is willing to pay for.
 *
 * Not a quality *setting* — the setting lives in `AppSettings` and is turned
 * into one of these per request, because the answer depends on the connection in
 * hand at the moment a track starts, not on what was chosen an hour ago on a
 * different network.
 */
sealed interface StreamRequest {
    /** Bit-exact, whatever it costs. Sources that cannot do it should say so rather than substitute. */
    data object Lossless : StreamRequest

    /** A transcode at or below [capKbps]. What a metered connection asks for. */
    data class Capped(val capKbps: Int) : StreamRequest

    /** Whatever the source considers its best lossy rendition. */
    data object Best : StreamRequest

    /** The ceiling in kbps, or null for the two requests that have none. */
    val kbpsCeiling: Int? get() = (this as? Capped)?.capKbps

    /** The name a source protocol uses for this tier, where one has tiers. */
    val tier: String
        get() = when (this) {
            is Lossless -> "LOSSLESS"
            is Best -> "BEST"
            is Capped -> if (capKbps >= 256) "HIGH" else "MEDIUM"
        }
}

/**
 * Whether a source is reachable and usable, asked before it is trusted with a
 * track.
 *
 * The distinction between [Unreachable] and [Rejected] is the whole point: a
 * server that is down is worth retrying and worth leaving enabled, and one that
 * refused the credentials is neither. Both look identical at the call site
 * otherwise, and a sources screen that renders them the same way sends people to
 * re-type a password that was never wrong.
 */
sealed interface SourceHealth {
    data class Ok(val detail: String? = null) : SourceHealth
    data class Unreachable(val reason: String) : SourceHealth
    data class Rejected(val reason: String) : SourceHealth

    val isOk: Boolean get() = this is Ok
}

/**
 * One place tracks can come from.
 *
 * All three methods may throw; [SourceResolver] and the sources screen are the
 * only callers, and both treat a throw as "this one didn't work" rather than
 * letting it reach the user as a crash.
 *
 * Implementations are constructed by [SourceRegistry] from a stored
 * [SourceConfig] and are expected to be cheap to build and safe to hold: no
 * connections are opened until something is actually asked for.
 */
interface MusicSource {

    /** The configured instance this was built from — unique across the registry. */
    val configId: String

    val kind: SourceKind

    /** What the user named it, falling back to the server's own hostname. */
    val displayName: String

    /** Reachability and credentials, for the sources screen and for skipping dead sources. */
    suspend fun health(): SourceHealth

    /**
     * Tracks matching [query], as [Song]s already tagged with this source's id so
     * that playing one comes back here — see [SourceRegistry.trackKey].
     *
     * @param waitForAll whether every backend this source fans out to is worth
     *   waiting for. False while someone is staring at a paused player, where a
     *   straggler costs more than the rows it would have added; true for the
     *   background pass that runs *during* playback and can afford the slow
     *   catalogue that turns out to be the one holding the FLAC.
     * @param request the stream this search is being made on behalf of, when it
     *   is being made on behalf of one. A catalogue that describes its rows by
     *   tier — most of them do, in the `audioQuality` a row advertises — answers
     *   a different question at each one, and a search made to find something to
     *   play at 128kbps should not be ranked on FLAC rows the caller is never
     *   going to ask for. Null is a search nobody is about to stream from: the
     *   user typing in the search box, where the best the catalogue has is
     *   exactly what should be shown.
     */
    suspend fun search(
        query: String,
        limit: Int = 25,
        waitForAll: Boolean = false,
        request: StreamRequest? = null,
    ): List<Song>

    /**
     * @param trackId this source's own id for the track, as issued by [search].
     * @return an openable stream, or null when this source turns out not to have
     *   the track after all — which is a miss, not an error, and lets
     *   [SourceResolver] move to the next source without logging a failure.
     */
    suspend fun stream(trackId: String, request: StreamRequest): SourceStream?
}

/** Implemented by sources that carry their [SourceConfig], so a rebuild can tell a real edit from a no-op. */
interface ConfigBacked {
    val config: SourceConfig
}

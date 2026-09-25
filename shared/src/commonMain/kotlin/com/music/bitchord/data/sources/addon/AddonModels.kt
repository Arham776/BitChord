package com.music.bitchord.data.sources.addon

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Port of upstream `data/sources/addon/AddonModels.kt` — the documents an addon
 * server exchanges with the app.
 *
 * Everything here is what the *server* says, kept deliberately separate from
 * [com.music.bitchord.data.sources.StreamFormat]: a source's claims and the
 * decoder's own measurements are different evidence, and merging them is how a
 * "24-bit 192kHz" badge ends up describing a 16/48 stream.
 */

@Serializable
data class AddonManifest(
    val id: String = "",
    val name: String = "",
    val version: String = "",
    val description: String = "",
    /** Free-form capability list. An addon declaring none of these cannot stream. */
    val resources: List<String> = emptyList(),
    val settings: List<AddonSetting> = emptyList(),
    val search: AddonSearchEndpoint? = null,
    val stream: AddonStreamEndpoint? = null,
    val links: List<AddonLink> = emptyList(),
) {
    /** What the sources screen shows. Never blank, even for a terse manifest. */
    val displayName: String get() = name.ifBlank { id.ifBlank { "Addon" } }

    /**
     * Whether this addon can take a track from a query to audio.
     *
     * The gate the sources screen tests against, and deliberately strict: an
     * addon that cannot search or cannot stream is not something that can be
     * trusted with a track, and accepting it would mean it silently returns
     * nothing on every track instead of saying so while the user is still looking
     * at the URL they pasted.
     */
    val isPlayable: Boolean get() = search != null && stream != null
}

@Serializable
data class AddonSearchEndpoint(
    val path: String = "/search",
    val method: String = "GET",
)

@Serializable
data class AddonStreamEndpoint(
    val path: String = "/stream",
    val method: String = "GET",
)

@Serializable
data class AddonLink(
    val label: String = "",
    val url: String = "",
)

@Serializable
data class AddonSetting(
    val key: String = "",
    val type: String = "string",
    val label: String = "",
    val description: String = "",
    val default: String? = null,
    val options: List<AddonOption> = emptyList(),
) {
    val defaultValue: String? get() = default
}

@Serializable
data class AddonOption(
    val value: String = "",
    val label: String = "",
) {
    val stringValue: String get() = value.ifBlank { label }
}

@Serializable
data class AddonSearchResponse(
    val tracks: List<AddonTrack> = emptyList(),
    @SerialName("next") val next: String? = null,
)

@Serializable
data class AddonTrack(
    val id: String = "",
    val title: String = "",
    val artist: String = "",
    val album: String? = null,
    val durationSec: Int? = null,
    val artworkUrl: String? = null,
    val codec: String? = null,
    val bitrateKbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
    val explicit: Boolean = false,
    val lossless: Boolean = false,
    val year: Int? = null,
    val isrc: String? = null,
) {
    /**
     * What this row claims about itself, for the resolver's ranking.
     *
     * Read from the row's own fields rather than trusted wholesale: an addon that
     * sets `lossless` but names an mp3 codec is describing a transcode it has not
     * performed, and ranking it as bit-exact would put it above a real FLAC.
     */
    val claimsLossless: Boolean
        get() = lossless || codec?.lowercase() in LOSSLESS_CODECS

    private companion object {
        val LOSSLESS_CODECS = setOf("flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff")
    }
}

@Serializable
data class AddonStream(
    val url: String = "",
    val codec: String? = null,
    val bitrateKbps: Int? = null,
    val sampleRateHz: Int? = null,
    val bitDepth: Int? = null,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
    /**
     * Whether this answer is worse than was asked for.
     *
     * An addon says so itself rather than the app inferring it from a bitrate,
     * because "320kbps because that is all I have" and "320kbps because you asked
     * for 320kbps" are the same bytes and different news.
     */
    val belowRequest: Boolean = false,
    val durationSec: Int? = null,
    /** ISO-8601 or epoch seconds. A five-minute default covers an addon that omits it. */
    val expiresAt: String? = null,
) {
    /**
     * Dolby Atmos, read from every spelling an addon might send.
     *
     * Enumerated rather than pattern-matched because the field name is not fixed
     * by the protocol: a server may say `isDolbyAtmos`, `atmos` or
     * `dolbyAtmos`, and a null answer here means the app never heard Atmos from
     * an addon that had it.
     */
    val isDolbyAtmos: Boolean
        get() = codec?.lowercase() in setOf("eac3-joc", "ec3-joc", "dolby-atmos")
}

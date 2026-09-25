package com.music.bitchord.data.sources

import com.music.bitchord.data.model.Song
import com.music.bitchord.data.model.artworkAt

/**
 * Port of upstream `data/sources/YouTubeSource.kt`.
 *
 * The source the app was built on, expressed through the same protocol as every
 * other one so it can be ranked against them rather than special-cased. It is
 * also the fallback: [SourceResolver] tries the other sources first and comes
 * back here, which is why it needs no configuration and why its [SourceConfig]
 * is seeded rather than typed.
 *
 * The one thing it will not do is serve lossless — YouTube has no such
 * rendition — which [SourceKind.canServeLossless] records, and which is what
 * stops the resolver asking it for a `StreamRequest.Lossless` in the first place.
 */
class YouTubeSource(override val config: SourceConfig) : MusicSource, ConfigBacked {

    override val configId: String get() = config.id
    override val kind: SourceKind get() = config.kind
    override val displayName: String get() = config.displayName

    /** Nothing to reach and nothing to authenticate, so always healthy. */
    override suspend fun health(): SourceHealth = SourceHealth.Ok(config.kind.label)

    /**
     * Delegates to the shared search the rest of the app already uses.
     *
     * [waitForAll] and [request] are accepted and ignored: there is one backend
     * behind this source, so there is nothing to wait for, and YouTube's ladder
     * has no tiers to rank against. Declaring the parameters rather than leaving
     * them out is what keeps a caller from having to know that.
     */
    override suspend fun search(
        query: String,
        limit: Int,
        waitForAll: Boolean,
        request: StreamRequest?,
    ): List<Song> = runCatching {
        com.music.bitchord.data.innertube.InnertubeParser
            .parseSearchSongs(com.music.bitchord.data.innertube.Innertube.search(query))
            .take(limit)
    }.getOrElse { emptyList() }

    /**
     * A YouTube track's stream is the `player` endpoint, which is the resolver's
     * own job — see [com.music.bitchord.data.innertube.StreamResolver].
     *
     * Returning null here rather than reaching for it is deliberate: the player
     * walk carries the stand-down bookkeeping, the format ladder and the probe
     * that makes a URL trustworthy, and a second, colder path to the same answer
     * would be one more place for all of that to be missing from. The resolver
     * knows this is YouTube and calls the player walk directly instead.
     */
    override suspend fun stream(trackId: String, request: StreamRequest): SourceStream? = null
}

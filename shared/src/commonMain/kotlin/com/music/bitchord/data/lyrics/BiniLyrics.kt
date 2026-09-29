package com.music.bitchord.data.lyrics

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Apple Music TTML again, from a third host — and the only one here that will
 * answer to a recording rather than to a name.
 *
 * The catalogue is the same one [BetterLyrics] serves; on a track both have, the
 * documents come back byte for byte identical. What it adds is a different
 * matcher over that catalogue, which is not nothing — it finds tracks
 * [BetterLyrics] misses, particularly outside the English-language releases —
 * and, more importantly, an index by ISRC.
 *
 * ## Why the ISRC matters
 *
 * Every other source here is asked for a title, an artist and a length, and
 * hopes. "Dracula" by Tame Impala exists as a single at 205 seconds and an
 * album cut at 206, with different words in places, and nothing in a fuzzy
 * match reliably tells those apart. An ISRC names one recording and only that
 * recording, so a lookup that has one cannot come back with the wrong edit.
 *
 * A search here also *reports* the ISRC of whatever it matched, which is where
 * [LyricsRepository] gets one to hand to the sources that can use it. That is
 * the whole arrangement: this asks by name once, and everything afterwards can
 * ask by recording.
 *
 * Two requests either way — the search returns a URL rather than the document,
 * so the TTML itself is a second fetch from the storage host.
 */
object BiniLyrics {

    private const val BASE = "https://lyrics-api.binimum.org/"

    /** Lyrics, and the ISRC of the recording they were matched to. */
    data class Match(val isrc: String?, val lines: List<LyricLineDto>)

    /**
     * Which recording this is, without fetching its words.
     *
     * The search is small — a couple of hundred bytes — and it is the only
     * request any source here makes whose answer is useful to the *other*
     * sources. [LyricsRepository] runs it on its own, before it asks anybody for
     * lyrics, so that everything downstream can name the recording rather than
     * describe it.
     */
    internal suspend fun identify(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        isrc: String? = null,
    ): Hit? {
        val query = buildMap {
            if (!isrc.isNullOrBlank()) {
                // Nothing else is worth sending: the recording is named, and a
                // title alongside it could only ever disagree with it.
                put("isrc", isrc)
            } else {
                put("track", title)
                put("artist", artist)
                if (!album.isNullOrBlank()) put("album", album)
                val seconds = durationMs / 1000
                if (seconds > 0) put("duration", seconds.toString())
            }
        }
        // A miss is a 404 here rather than an empty result set, and a non-2xx is
        // read as a null body, so this is the miss.
        val body = lyricsGet(BASE, query = query) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(Response.serializer(), body) }
            .getOrNull() ?: return null
        val candidates = response.results.orEmpty()
        if (!isrc.isNullOrBlank()) {
            // When the caller already has a recording identifier, do not let a
            // search result for a neighbouring edit replace it. If the service
            // drops the ID from its result, only accept the fallback when its
            // title, artist and duration still identify the requested recording.
            return selectHitForIsrc(candidates, isrc, title, artist, durationMs)
        }
        return selectHit(candidates, title, artist, durationMs)
    }

    internal fun selectHitForIsrc(
        candidates: List<Hit>,
        isrc: String,
        title: String,
        artist: String,
        durationMs: Long,
    ): Hit? = candidates.firstOrNull { it.isrc.equals(isrc.trim(), ignoreCase = true) }
        ?: selectHit(candidates.filter { it.isrc.isNullOrBlank() }, title, artist, durationMs)

    /** Select by recording identity before its ISRC is shared with other providers. */
    internal fun selectHit(
        candidates: List<Hit>,
        title: String,
        artist: String,
        durationMs: Long,
    ): Hit? = candidates.mapNotNull { candidate ->
        val score = LyricsMatching.candidateScore(
            wantedTitle = title,
            wantedArtist = artist,
            wantedDurationMs = durationMs,
            candidateTitle = candidate.trackName,
            candidateArtist = candidate.artistName,
            candidateDurationMs = candidate.duration.toDurationMs(),
            requireArtist = true,
        ) ?: return@mapNotNull null
        candidate to score
    }.maxByOrNull { it.second }?.first

    private fun Int?.toDurationMs(): Long = when {
        this == null || this <= 0 -> 0L
        this < 10_000 -> this.toLong() * 1000L
        else -> this.toLong()
    }

    /** The document a search already found, fetched and parsed. */
    internal suspend fun lyricsFor(hit: Hit): Match? {
        val document = hit.lyricsUrl?.takeIf { it.isNotBlank() } ?: return null
        val ttml = lyricsGet(document) ?: return null
        val lines = TtmlLyrics.parse(ttml).takeIf { it.isNotEmpty() } ?: return null
        return Match(hit.isrc?.takeIf { it.isNotBlank() }, lines)
    }

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        isrc: String? = null,
    ): Match? = identify(title, artist, durationMs, album, isrc)?.let { lyricsFor(it) }

    @Serializable
    internal data class Response(
        val total: Int? = null,
        /** How it matched — `HIT-EXACT` and friends. Logged, not acted on. */
        val source: String? = null,
        val results: List<Hit>? = null,
    )

    @Serializable
    internal data class Hit(
        @SerialName("track_name") val trackName: String? = null,
        @SerialName("artist_name") val artistName: String? = null,
        @SerialName("album_name") val albumName: String? = null,
        val duration: Int? = null,
        val isrc: String? = null,
        /** `word` or `line`; the document itself is the authority. */
        @SerialName("timing_type") val timingType: String? = null,
        val lyricsUrl: String? = null,
    )
}

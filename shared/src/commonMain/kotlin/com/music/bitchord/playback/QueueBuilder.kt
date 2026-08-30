package com.music.bitchord.playback

import com.music.bitchord.data.model.Song

/**
 * Port of upstream `playback/QueueBuilder.kt` — pure logic, unchanged. The
 * two problems it solves carry over: YouTube watch queues carry the same
 * recording twice under different videoIds, and a radio mix leans hard on the
 * seed's own artist.
 */
object QueueBuilder {

    /** No more than this many tracks by one artist in a single batch. */
    private const val PER_ARTIST_LIMIT = 2

    /** The artist the station was seeded on gets more room, but not the run of it. */
    private const val SEED_ARTIST_LIMIT = 4

    /**
     * The subset of [candidates] worth appending after [existing]: nothing
     * already queued, nothing repeated, at most [limit] tracks.
     */
    fun extend(existing: List<Song>, candidates: List<Song>, limit: Int): List<Song> {
        val taken = existing.toMutableList()
        val perArtist = mutableMapOf<String, Int>()
        val seedArtists = existing.lastOrNull()?.artist?.let(::artistSet).orEmpty()
        val out = mutableListOf<Song>()

        // The catalogue cut is the one a music app wants; videos only stand in
        // when there is nothing else.
        val songsOnly = candidates.filterNot { it.isVideo }
        val ordered = songsOnly.ifEmpty { candidates }

        for (candidate in ordered) {
            if (out.size >= limit) break
            if (taken.any { isSameRecording(it, candidate) }) continue

            val artists = artistSet(candidate.artist)
            val key = artists.minOrNull()
            if (key != null) {
                val cap = if (artists.any { it in seedArtists }) {
                    SEED_ARTIST_LIMIT
                } else {
                    PER_ARTIST_LIMIT
                }
                val played = perArtist[key] ?: 0
                if (played >= cap) continue
                perArtist[key] = played + 1
            }

            taken += candidate
            out += candidate
        }
        return out
    }

    /**
     * Whether two entries are the same recording. Ids differ between the audio
     * and video cuts of a track, which is exactly the case id equality misses.
     */
    fun isSameRecording(a: Song, b: Song): Boolean {
        if (a.videoId == b.videoId) return true
        val title = normalisedTitle(a.title)
        if (title.isEmpty() || title != normalisedTitle(b.title)) return false
        val left = artistSet(a.artist)
        val right = artistSet(b.artist)
        return left.isEmpty() || right.isEmpty() || left.any { it in right }
    }

    /**
     * `Kesariya (From "Brahmastra") | Official Video` and `Kesariya` are one
     * recording as far as a queue is concerned. Remix and cover markers are
     * deliberately left in — those really are different tracks.
     */
    internal fun normalisedTitle(raw: String): String = raw.lowercase()
        .substringBefore(" | ")
        .replace(NOISE, " ")
        .replace(PUNCTUATION, " ")
        .replace(SPACES, " ")
        .trim()

    /** The cast behind a credit, split out so billing order stops mattering. */
    internal fun artistSet(raw: String): Set<String> = raw.lowercase()
        .replace(TOPIC, " ")
        .split(",", "&", "·", "•", ";", " feat", " ft.", " ft ", " x ", " with ")
        .map { it.replace(PUNCTUATION, " ").replace(SPACES, " ").trim() }
        .filter { it.isNotEmpty() }
        .toSet()

    private val NOISE = Regex(
        """\((?:official|lyric|lyrics|lyrical|audio|video|visuali[sz]er|full song|hd|4k)[^)]*\)""" +
            """|\(from[^)]*\)""" +
            """|\[[^]]*]""" +
            """|\b(?:official (?:video|audio|music video)|lyrical video|full video|4k video)\b""",
        RegexOption.IGNORE_CASE,
    )
    private val TOPIC = Regex("""\s*-\s*topic\b""", RegexOption.IGNORE_CASE)
    private val PUNCTUATION = Regex("""[^\p{L}\p{N}]+""")
    private val SPACES = Regex("""\s+""")
}

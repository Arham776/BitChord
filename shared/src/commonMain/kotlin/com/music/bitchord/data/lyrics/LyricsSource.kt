package com.music.bitchord.data.lyrics

/**
 * The databases [LyricsRepository] can ask, in the order it asks them.
 *
 * Declaration order is the default priority — [AppSettings] lyrics source
 * defaults fall back to [LyricsSource.entries] verbatim.
 */
enum class LyricsSource(
    val label: String,
    val detail: String,
    val wordSynced: Boolean,
) {
    LYRICS_PLUS(
        label = "LyricsPlus",
        detail = "Syllable by syllable, on community mirrors",
        wordSynced = true,
    ),
    /**
     * The one that hands out ISRCs.
     *
     * Declared second because enabling it also enables the identify pass that
     * makes every *other* source's match better — see [LyricsRepository]. It is
     * the only source this app contacts outside the race, and only when it is
     * switched on.
     */
    BINI_LYRICS(
        label = "BiniLyrics",
        detail = "Apple Music timings, and the recording's ISRC for everything else",
        wordSynced = true,
    ),
    PAXSENIX(
        label = "PaxSenix",
        detail = "Apple Music timings again, on a second host",
        wordSynced = true,
    ),
    BETTER_LYRICS(
        label = "BetterLyrics",
        detail = "Apple Music timings, word by word",
        wordSynced = true,
    ),
    /**
     * QQ Music's catalogue through the same host's other endpoint.
     *
     * Separate because it is a different catalogue, not a second attempt at the
     * same one: a track BetterLyrics has and Portato does not is the normal
     * case, and which is worth asking depends on what the track is.
     */
    BETTER_LYRICS_PORTATO(
        label = "BetterLyrics Portato",
        detail = "QQ Music karaoke timings, on a second endpoint",
        wordSynced = true,
    ),
    SIMP_MUSIC(
        label = "SimpMusic",
        detail = "Matched on the video, so never the wrong edit",
        wordSynced = true,
    ),
    /**
     * YouTube's own transcript for the video being played.
     *
     * Asked about a video id rather than a name, so it cannot be wrong about which
     * song this is — and that is worth more than its timing, which is only
     * line-stamped. It also covers the long tail nobody has uploaded lyrics for,
     * which is most of a catalogue nobody has written lyrics for.
     */
    YOUTUBE_TRANSCRIPT(
        label = "YouTube Transcript",
        detail = "YouTube's own captions for this video, line by line",
        wordSynced = false,
    ),
    /**
     * The Lyrics tab on YouTube Music.
     *
     * Unsynced and therefore last among the video-matched sources: it is
     * authoritative about the words and no use at all for when they are said.
     */
    YOUTUBE_MUSIC(
        label = "YouTube Music",
        detail = "YouTube Music's own lyrics, with no timing",
        wordSynced = false,
    ),
    KUGOU(
        label = "KuGou",
        detail = "Whole lines, strong outside the English catalogue",
        wordSynced = false,
    ),
    LRCLIB(
        label = "LRCLIB",
        detail = "Whole lines only, and always up",
        wordSynced = false,
    ),
    MUSIXMATCH(
        label = "Musixmatch",
        detail = "Whole lines, from the biggest lyrics database there is",
        wordSynced = false,
    ),
    /**
     * Community-submitted rather than licensed, so it sometimes has a track none
     * of the others do and is thin everywhere else. Low for that reason, not
     * because its contents are worse.
     */
    UNISON(
        label = "Unison",
        detail = "Community submissions; can be word synced, line synced or plain",
        wordSynced = true,
    ),
    /**
     * A page scraper with no API, so it breaks when the page changes and there
     * is nothing to tell that apart from a miss. Last, and here for the long tail
     * of older catalogue none of the licensed sources carry.
     */
    MEGALOBIZ(
        label = "Megalobiz",
        detail = "Scraped community LRC; the long tail, and the first to break",
        wordSynced = false,
    ),
    ;

    companion object {
        private val LEGACY = mapOf(
            "BETTER" to BETTER_LYRICS,
            "PLUS" to LYRICS_PLUS,
            "SIMP" to SIMP_MUSIC,
        )

        fun fromName(raw: String): LyricsSource? {
            val name = raw.trim()
            if (name.isEmpty()) return null
            entries.firstOrNull { it.name == name }?.let { return it }
            return LEGACY[name]
        }
    }
}

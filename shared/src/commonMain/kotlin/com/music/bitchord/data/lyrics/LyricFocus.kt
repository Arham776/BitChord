package com.music.bitchord.data.lyrics

/**
 * Which lyric lines are being sung right now, and how far ahead the list should
 * scroll to show them. Upstream `LyricFocus.kt` and the `scrollLead` beside it,
 * ported whole and kept in the same place — a separate file from the panel,
 * because these are two questions about a list of lines and nothing to do with
 * how a line is drawn.
 */
object LyricFocus {

    /**
     * How far ahead of the playhead the list scrolls, at least.
     *
     * Not zero: a list that scrolls *to* the line being sung puts the next line
     * below the fold, so the reader is always one line behind and the scroll
     * spends the whole song catching up. Leading means the next line is on screen
     * before it is sung.
     */
    const val SCROLL_LEAD_MIN_MS: Long = 350L

    /**
     * …and at most.
     *
     * A long instrumental would otherwise scroll far enough ahead to park the
     * line being sung at the very top and leave a screen of upcoming words, which
     * reads as having jumped somewhere rather than as following the song.
     */
    const val SCROLL_LEAD_MAX_MS: Long = 500L

    /**
     * The lines that are being sung at [positionMs].
     *
     * Usually one, and the latest line whose stamp has passed. But a line that
     * says when it ends keeps its place until it actually ends — including after
     * the *next* line's stamp has arrived, which is the case that matters: a line
     * that runs past the next stamp used to lose its highlight the moment the
     * next timestamp was reached, so the tail of it was never shown as sung.
     *
     * That is also how a duet stays legible: the answering line overlaps the lead
     * and both are being sung at once.
     *
     * A line with no known end is only active while it is the latest — nothing
     * says how long it lasts, so holding it would hold it for ever. A gap is
     * never active at all, however its timestamp falls.
     */
    fun activeRows(lines: List<LyricLineDto>, positionMs: Long): List<Int> {
        // An unsynced transcript answers nothing at all. Every stamp is zero, so
        // the search below would find the *last* line for any position and light
        // it up for the whole song. Upstream guards this at the call site; here it
        // is guarded inside, because a function called "which lines are being
        // sung" that answers "one of them" for a transcript with no times is a
        // trap for every caller rather than for one.
        if (!isSynced(lines)) return emptyList()
        val latest = lines.indexOfLast { it.timeMs <= positionMs }
        if (latest < 0) return emptyList()
        return (0..latest).filter { index ->
            val line = lines[index]
            index == latest || (
                !line.isGap &&
                    (line.hasKnownEnd || line.background?.hasKnownEnd == true) &&
                    line.timeMs <= positionMs && positionMs < line.endMs
                )
        }
    }

    /**
     * How far ahead of the playhead to scroll, in milliseconds.
     *
     * The gap to the next line, bounded: long enough that the next line arrives
     * before it is sung, short enough that an instrumental does not scroll the
     * list halfway down.
     *
     * Before the first line there is no current line to measure a run-up from,
     * and the minimum is the answer — a track paused at 0:00 whose words start a
     * few seconds in is every track that opens on an intro.
     */
    fun scrollLead(lines: List<LyricLineDto>, positionMs: Long): Long {
        val current = lines.indexOfLast { it.timeMs <= positionMs }
        if (current < 0) return SCROLL_LEAD_MIN_MS
        val next = lines.getOrNull(current + 1) ?: return SCROLL_LEAD_MIN_MS
        val gap = next.timeMs - lines[current].endMs
        return gap.coerceIn(SCROLL_LEAD_MIN_MS, SCROLL_LEAD_MAX_MS)
    }

    /**
     * The line the list should be showing, which is the first of the active ones.
     *
     * The *first*, not the last: with a duet the lead comes before the answer, and
     * scrolling to the answer would put the lead off the top of the screen while
     * it was still the line being sung.
     */
    fun leadRow(lines: List<LyricLineDto>, positionMs: Long): Int {
        val active = activeRows(lines, positionMs)
        if (active.isNotEmpty()) return active.first()
        if (!isSynced(lines)) return -1
        return lines.indexOfLast { it.timeMs <= positionMs + scrollLead(lines, positionMs) }
    }

    /** Whether any line carries a real timestamp, as opposed to a plain transcript. */
    fun isSynced(lines: List<LyricLineDto>): Boolean = lines.any { it.timeMs > 0L }
}

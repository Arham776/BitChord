package com.music.bitchord.data.settings

/**
 * How well a settings section matched a search query.
 *
 * Declared strongest-first, which reads well and is the wrong thing to compare
 * with `ordinal` — see [strength], which is what the ranking actually uses.
 */
enum class SettingsMatch {
    /** The query is the whole title, ignoring case. */
    EXACT,

    /** The title starts with, or contains, the query. */
    TITLE,

    /**
     * A search term matched — the setting's own name, a synonym, or the section
     * it lives in.
     */
    TERM,

    /** Nothing. */
    NONE,

    ;

    /**
     * How good a match this is; higher wins.
     *
     * An explicit number rather than `ordinal`, because the declaration order above
     * puts the *strongest* first and `NONE` — the weakest — last, so `ordinal`
     * ranks them exactly backwards. Comparing on it drops everything but an exact
     * title match and picks the weakest match whenever two are candidates. Writing
     * it out also survives anyone reordering the constants, which is a change that
     * looks harmless.
     */
    val strength: Int
        get() = when (this) {
            EXACT -> 3
            TITLE -> 2
            TERM -> 1
            NONE -> 0
        }
}

/**
 * Matching for the settings search.
 *
 * The policy lives here rather than in the host because it is a judgement with
 * edge cases, and edge cases in a search box are felt rather than read: someone
 * typing "cross" should find "Crossfade" without having to know it is called
 * "Crossfade", and someone typing "lossless" should find the setting labelled
 * "Lossless" rather than the one labelled "Download quality".
 */
object SettingsSearch {

    /**
     * How well [query] matches a section titled [title] with [terms].
     *
     * @param terms the things a listener might type that are *not* the title: the
     *   settings inside, and the words they would use for them. This is the whole
     *   difference between a search box that works and one that only finds titles
     *   — a settings screen's titles are things like "Playback" and "Storage",
     *   which nobody types when they mean "crossfade".
     */
    fun match(query: String, title: String, terms: List<String>): SettingsMatch {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return SettingsMatch.TITLE
        val lowerTitle = title.lowercase()
        if (lowerTitle == needle) return SettingsMatch.EXACT
        // Substring rather than word-prefix, because the common case is typing the
        // first few letters of a long word.
        if (lowerTitle.contains(needle)) return SettingsMatch.TITLE
        val found = terms.any { term -> term.lowercase().contains(needle) }
        return if (found) SettingsMatch.TERM else SettingsMatch.NONE
    }

    /**
     * Whether a section is worth showing for [query].
     *
     * An empty query shows everything, which is the point of it being a filter
     * rather than a mode: clearing the box must not empty the screen.
     */
    fun matches(query: String, title: String, terms: List<String>): Boolean =
        match(query, title, terms) != SettingsMatch.NONE

    /**
     * The best match across several entries, or null when none.
     *
     * So a results list can lead with the section whose *title* was typed rather
     * than one that merely mentions the word somewhere in its rows.
     *
     * Ties go to the earlier entry, deliberately: otherwise the order the sections
     * happen to be declared in decides which of two equally good answers appears
     * first, and that is not a decision anybody meant to make.
     */
    fun bestOf(
        query: String,
        entries: List<Pair<String, List<String>>>,
    ): Pair<Int, SettingsMatch>? {
        var bestIndex = -1
        // Compared with `<` against a nullable rather than seeded with NONE: NONE
        // is the *highest* ordinal, because it is the "no verdict" case and reads
        // last — so seeding with it means nothing can ever beat it and every
        // section but an exact title match is dropped.
        var best: SettingsMatch? = null
        entries.forEachIndexed { index, entry ->
            val found = match(query, entry.first, entry.second)
            if (found == SettingsMatch.NONE) return@forEachIndexed
            if (best == null || found.strength > best!!.strength) {
                best = found
                bestIndex = index
            }
        }
        return bestIndex.takeIf { it >= 0 }?.let { it to best!! }
    }
}

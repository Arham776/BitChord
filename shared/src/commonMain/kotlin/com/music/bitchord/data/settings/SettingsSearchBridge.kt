package com.music.bitchord.data.settings

/**
 * Swift-facing seam over [SettingsSearch].
 *
 * Synchronous on purpose, unlike most of the bridges here: this is a string
 * comparison, and a coroutine around one would make the search box lag by a frame
 * for no reason. The alternative is the host reimplementing the policy — which is
 * how the terms and the matching drift apart.
 *
 * There is no "strongest match" entry point, because the host does not need one:
 * the sections are already in a deliberate order, and offering that order is better
 * than offering a ranking, which would move a section around as the query changes
 * and make the list feel like it is shuffling.
 */
object SettingsSearchBridge {

    /**
     * Whether a section is worth showing for [query].
     *
     * @param termsCsv the section's search terms, joined by the unit separator.
     *   A string rather than a list because the Swift call carries a `[String]` as
     *   a bridged `KotlinArray`, which cannot be built without a companion
     *   allocation for what is usually eight words.
     */
    fun matches(query: String, title: String, termsCsv: String): Boolean =
        SettingsSearch.matches(query, title, terms(termsCsv))

    /**
     * How well a section matched, by name — `EXACT`, `TITLE`, `TERM` or `NONE`.
     *
     * Exposed so the host can say *why* a section is showing when the title
     * matched but the listener was looking for a setting inside it: the difference
     * between "here is Playback, because you typed Playback" and "here is
     * Playback, because it has crossfade in it".
     */
    fun qualityOf(query: String, title: String, termsCsv: String): String =
        SettingsSearch.match(query, title, terms(termsCsv)).name

    private fun terms(csv: String): List<String> =
        if (csv.isEmpty()) emptyList() else csv.split(SEPARATOR)

    /**
     * ASCII unit separator.
     *
     * Not a comma: the terms are phrases with spaces in them and some contain
     * punctuation, and a separator that can appear in the data is a separator that
     * will eventually split a term in half.
     */
    private const val SEPARATOR = "\u001F"
}

package com.music.bitchord.data.settings

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The settings search box.
 *
 * A settings screen's visible titles are things like "Playback" and "Storage" —
 * which nobody types when they mean "crossfade". So the terms are the whole
 * feature and the title matching is the easy half, and these tests are mostly
 * about the terms.
 */
class SettingsSearchTest {

    private val playback = listOf(
        "crossfade", "gapless", "automix", "autoplay", "skip silence",
        "playback speed", "spatial audio", "fade",
    )

    // ---- Titles -----------------------------------------------------------

    @Test
    fun `the exact title is the best possible match`() {
        assertEquals(
            SettingsMatch.EXACT,
            SettingsSearch.match("Playback", "Playback", playback),
        )
    }

    @Test
    fun `a title match ignores case`() {
        // An exact match ignoring case is *exact*, not merely a title match — the
        // distinction is what lets a results list lead with the section whose name
        // was typed.
        assertEquals(
            SettingsMatch.EXACT,
            SettingsSearch.match("PLAYBACK", "Playback", playback),
        )
    }

    @Test
    fun `a partial title is still a title match`() {
        // Typing the first few letters is how people search.
        assertEquals(
            SettingsMatch.TITLE,
            SettingsSearch.match("play", "Playback", playback),
        )
    }

    @Test
    fun `a title match outranks a term match`() {
        // Someone typing "play" means the Playback section, not the one that
        // happens to mention a setting beginning with "play".
        assertTrue(
            SettingsSearch.match("play", "Playback", emptyList()).strength >
                SettingsSearch.match("play", "Storage", listOf("playback queue")).strength,
        )
    }

    @Test
    fun `strength ranks the matches strongest first`() {
        // Pinned because the enum's declaration order is the *opposite* of its
        // strength — the constants read strongest-first, so `ordinal` ranks them
        // backwards. Anything that ranks on strength must not use ordinal.
        val ranked = listOf(SettingsMatch.NONE, SettingsMatch.TERM, SettingsMatch.TITLE, SettingsMatch.EXACT)
        assertEquals(
            listOf(SettingsMatch.EXACT, SettingsMatch.TITLE, SettingsMatch.TERM, SettingsMatch.NONE),
            ranked.sortedByDescending { it.strength },
        )
    }

    // ---- Terms ------------------------------------------------------------

    @Test
    fun `a term finds the section that holds the setting`() {
        // The case this whole file exists for.
        assertEquals(
            SettingsMatch.TERM,
            SettingsSearch.match("crossfade", "Playback", playback),
        )
    }

    @Test
    fun `a partial term matches`() {
        // "cross" should find "Crossfade" without the listener knowing its name.
        assertEquals(
            SettingsMatch.TERM,
            SettingsSearch.match("cross", "Playback", playback),
        )
    }

    @Test
    fun `a term matches ignoring case`() {
        assertEquals(
            SettingsMatch.TERM,
            SettingsSearch.match("SPATIAL", "Playback", playback),
        )
    }

    @Test
    fun `a term that is a substring of an unrelated word still matches`() {
        // Documented rather than prevented: a search box that refused "art" for
        // "Artist" is worse than one that also matches "Start". Narrowing this
        // needs word boundaries, which then fails on plurals and hyphenation.
        assertEquals(
            SettingsMatch.TERM,
            SettingsSearch.match("art", "Playback", listOf("Artist")),
        )
    }

    // ---- Nothing ----------------------------------------------------------

    @Test
    fun `an unrelated word matches nothing`() {
        assertEquals(
            SettingsMatch.NONE,
            SettingsSearch.match("helicopter", "Playback", playback),
        )
        assertFalse(SettingsSearch.matches("helicopter", "Playback", playback))
    }

    @Test
    fun `an empty query shows everything`() {
        // A filter, not a mode: clearing the box must not empty the screen.
        assertEquals(
            SettingsMatch.TITLE,
            SettingsSearch.match("", "Playback", playback),
        )
        assertTrue(SettingsSearch.matches("   ", "Playback", playback))
    }

    @Test
    fun `surrounding whitespace in the query is ignored`() {
        // Nobody types a trailing space deliberately; refusing to match because of
        // one is the kind of small rudeness a search box should not have.
        assertEquals(
            SettingsMatch.EXACT,
            SettingsSearch.match("  Playback  ", "Playback", playback),
        )
    }

    @Test
    fun `a section with no terms is found by its title alone`() {
        assertTrue(SettingsSearch.matches("about", "About", emptyList()))
        assertFalse(SettingsSearch.matches("crossfade", "About", emptyList()))
    }

    // ---- Ranking across sections -----------------------------------------

    @Test
    fun `the best of several entries is the titled one`() {
        val entries = listOf(
            "Storage" to listOf("cache", "downloads", "folder"),
            "Playback" to listOf("crossfade"),
            "Appearance" to listOf("theme", "dark mode"),
        )
        val best = SettingsSearch.bestOf("play", entries)
        // Playback wins on its *title*, even though nothing anywhere mentions
        // "play" as a setting.
        assertEquals(1, best?.first)
        assertEquals(SettingsMatch.TITLE, best?.second)
        assertNull(SettingsSearch.bestOf("nothing here", entries))
    }

    @Test
    fun `no entry matching means no best`() {
        assertNull(
            SettingsSearch.bestOf("helicopter", listOf("Playback" to listOf("crossfade"))),
        )
    }

    @Test
    fun `an empty entry list has no best`() {
        assertNull(SettingsSearch.bestOf("play", emptyList()))
    }

    @Test
    fun `the first entry wins a tie`() {
        // Deterministic, or the order the sections happen to be declared in
        // decides which of two equally-good answers appears first.
        val entries = listOf("One" to listOf("x"), "Two" to listOf("x"))
        assertEquals(0, SettingsSearch.bestOf("x", entries)?.first)
    }
}

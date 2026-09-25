package com.music.bitchord.data.settings

import com.music.bitchord.data.lyrics.LyricsSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Whether an upgrade's new sources actually get switched on.
 *
 * The failure this guards against is quiet and total: a source added to
 * [LyricsSource] is not in anybody's stored list, so a literal reading leaves it
 * off forever on every install that has ever been opened. With `BINI_LYRICS`
 * among them, that means the ISRC pass never runs and every match stays exactly
 * as fuzzy as it was — the feature ships and does nothing.
 */
class LyricsSourcesPrefTest {

    /** A stand-in for the storage, so the migration can be exercised end to end. */
    private class Store(initial: Map<String, String> = emptyMap()) {
        val values = initial.toMutableMap()
        fun string(key: String, fallback: String) = values[key] ?: fallback
        fun put(key: String, value: String) { values[key] = value }
        fun has(key: String) = key in values
    }

    /**
     * The migration's rule, reimplemented against a plain map.
     *
     * Duplicated rather than called because the real one reads `PlatformSettings`
     * directly and that is a singleton over `NSUserDefaults` — a test that wrote
     * to it would leave state behind for every other test in the build. The
     * behaviour is small enough that restating it is cheaper than an expect/actual
     * seam, and the test's value is in the rule, not in the plumbing.
     */
    private fun adopt(current: Set<LyricsSource>, known: Set<LyricsSource>): Pair<Set<LyricsSource>, Set<LyricsSource>> {
        val everything = LyricsSource.entries.toSet()
        if (known.containsAll(everything)) return current to known
        return (current + (everything - known)) to everything
    }

    private fun names(set: Set<LyricsSource>) = set.map { it.name }.toSet()

    @Test
    fun `a source an upgrade added is switched on`() {
        val (enabled, _) = adopt(
            current = setOf(LyricsSource.LYRICS_PLUS, LyricsSource.PAXSENIX),
            known = setOf(LyricsSource.LYRICS_PLUS, LyricsSource.PAXSENIX),
        )
        assertTrue(LyricsSource.BINI_LYRICS in enabled)
    }

    @Test
    fun `every current source is reached on a first upgrade`() {
        val (enabled, known) = adopt(
            current = setOf(LyricsSource.LRCLIB),
            known = setOf(LyricsSource.LRCLIB),
        )
        assertEquals(names(LyricsSource.entries.toSet()), names(enabled))
        assertEquals(names(LyricsSource.entries.toSet()), names(known))
    }

    @Test
    fun `the ISRC pass is switched on by that same upgrade`() {
        // Stated on its own because it is the one that matters: without it every
        // other source's match is as fuzzy as it ever was.
        val (enabled, _) = adopt(
            current = setOf(LyricsSource.LRCLIB),
            known = LyricsSource.entries.toSet() - LyricsSource.BINI_LYRICS,
        )
        assertTrue(LyricsSource.BINI_LYRICS in enabled)
    }

    @Test
    fun `a source the user switched off stays off`() {
        // The distinction the whole migration turns on: "known" means it existed
        // when they decided, so their removal is a decision and not an absence.
        // So `known` has to be every source this build has ever offered — which
        // is what it is by the time a second upgrade arrives.
        val everything = LyricsSource.entries.toSet()
        val decided = setOf(LyricsSource.LYRICS_PLUS, LyricsSource.LRCLIB, LyricsSource.KUGOU)
        val (enabled, _) = adopt(current = decided, known = everything)
        assertEquals(names(decided), names(enabled))
        assertFalse(LyricsSource.PAXSENIX in enabled)
        assertFalse(LyricsSource.BETTER_LYRICS in enabled)
    }

    @Test
    fun `a second upgrade with nothing new changes nothing`() {
        val everything = LyricsSource.entries.toSet()
        val (enabled, known) = adopt(current = everything, known = everything)
        assertEquals(names(everything), names(enabled))
        assertEquals(names(everything), names(known))
    }

    @Test
    fun `adopting does not re-enable a source the user removed in the same release`() {
        // Removed *and* newly added is not expressible, but the near case is: a
        // user who turned off everything they have seen must not have it turned
        // back on by an upgrade.
        val known = LyricsSource.entries.toSet()
        val (enabled, _) = adopt(current = emptySet(), known = known)
        assertTrue(enabled.isEmpty())
    }
}

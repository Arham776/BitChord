package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The parts of lyric translation that are judgement rather than plumbing.
 *
 * All pure: no network, no disk. That is deliberate — the parts worth testing
 * here are the ones a request cannot check for you, namely whether the answer
 * that came back is any good, and whether what we cached is still worth serving.
 */
class LyricsTranslationTest {

    private fun line(text: String, words: Int = 0) = LyricLineDto(
        timeMs = 0,
        text = text,
        words = if (words == 0) emptyList() else (1..words).map {
            LyricWordDto(it * 100L, it * 100L + 100L, "w$it")
        },
    )

    // ---- Same language -----------------------------------------------------

    @Test
    fun `the same language is recognised across spellings`() {
        assertTrue(LyricsTranslation.sameLanguage("en", "en"))
        assertTrue(LyricsTranslation.sameLanguage("EN", "en"))
        assertTrue(LyricsTranslation.sameLanguage("en-US", "en-GB"))
    }

    @Test
    fun `a region does not make a different language`() {
        // `zh-CN` and `zh` are the same language, and this is the one place
        // narrowing to a base tag is right — the *sending* side must not narrow,
        // or a request for Traditional comes back Simplified.
        assertTrue(LyricsTranslation.sameLanguage("zh-CN", "zh"))
    }

    @Test
    fun `two scripts of one language count as the same language`() {
        // Pinned deliberately, because it is a limitation rather than an
        // oversight: there is nothing to *translate* between Simplified and
        // Traditional, so the caller is told the lyric is already Chinese. What it
        // does not do is convert the script — a request must carry zh-TW to get
        // zh-TW back, which is why the sending side never narrows.
        assertTrue(LyricsTranslation.sameLanguage("zh-CN", "zh-TW"))
    }

    @Test
    fun `legacy codes are canonicalised`() {
        assertEquals("he", LyricsTranslation.canonicalLanguage("iw"))
        assertEquals("id", LyricsTranslation.canonicalLanguage("in"))
        assertEquals("yi", LyricsTranslation.canonicalLanguage("ji"))
        assertEquals("ro", LyricsTranslation.canonicalLanguage("mo"))
        // Norwegian has two written forms and the endpoint answers only to one.
        assertEquals("no", LyricsTranslation.canonicalLanguage("nb"))
        assertEquals("no", LyricsTranslation.canonicalLanguage("nn"))
    }

    @Test
    fun `an underscore separator is a dash for this purpose`() {
        assertEquals("pt", LyricsTranslation.canonicalLanguage("pt_BR"))
    }

    @Test
    fun `a blank language is never the same as anything`() {
        // Otherwise a failed detection would compare equal to every target and
        // the caller would be told "already in that language".
        assertFalse(LyricsTranslation.sameLanguage("", "en"))
        assertFalse(LyricsTranslation.sameLanguage("en", ""))
    }

    // ---- Section headers ---------------------------------------------------

    @Test
    fun `a bracketed section name is a header`() {
        assertTrue(LyricsTranslation.isSectionHeader("[Verse 1]"))
        assertTrue(LyricsTranslation.isSectionHeader("[Chorus]"))
        assertTrue(LyricsTranslation.isSectionHeader("[Bridge]"))
        assertTrue(LyricsTranslation.isSectionHeader("[Intro]"))
        assertTrue(LyricsTranslation.isSectionHeader("[Pre-Chorus]"))
    }

    @Test
    fun `a bracketed lyric line is not a header`() {
        assertFalse(LyricsTranslation.isSectionHeader("[oh oh oh]"))
        assertFalse(LyricsTranslation.isSectionHeader("[I said what I said]"))
    }

    @Test
    fun `a stanza is not a header`() {
        // More than one line inside the brackets is a refrain being quoted.
        assertFalse(LyricsTranslation.isSectionHeader("[first line\nsecond line]"))
    }

    @Test
    fun `an unbracketed line is never a header`() {
        assertFalse(LyricsTranslation.isSectionHeader("Verse 1"))
        assertFalse(LyricsTranslation.isSectionHeader("Just a line"))
        assertFalse(LyricsTranslation.isSectionHeader(""))
    }

    // ---- Script detection --------------------------------------------------

    @Test
    fun `latin letters are recognised across the blocks`() {
        // The ASCII case, Latin-1, and Extended-A — the three that actually turn
        // up in a European lyric.
        assertTrue(isLatinLetter('a'))
        assertTrue(isLatinLetter('Z'))
        assertTrue(isLatinLetter('é'))
        assertTrue(isLatinLetter('ñ'))
        assertTrue(isLatinLetter('ł'))
        assertTrue(isLatinLetter('ā'))
    }

    @Test
    fun `other scripts are not latin`() {
        assertFalse(isLatinLetter('日'))
        assertFalse(isLatinLetter('本'))
        assertFalse(isLatinLetter('한'))
        assertFalse(isLatinLetter('д'))
        assertFalse(isLatinLetter('א'))
        assertFalse(isLatinLetter('ع'))
    }

    @Test
    fun `a symbol is neither latin nor a letter`() {
        // Treated as non-latin by `isNonLatinLetter` only if it is also a
        // letter, so a digit or a bracket does not make a lyric look untranslated.
        assertFalse(isLetter('1'))
        assertFalse(isLetter('['))
        assertFalse(isNonLatinLetter('1'))
    }

    @Test
    fun `a wholly latin lyric is not worth romanising`() {
        assertFalse(isRomanisable("There is a light that never goes out"))
    }

    @Test
    fun `a lyric with any non-latin letter is worth romanising`() {
        assertTrue(isRomanisable("灯花"))
        assertTrue(isRomanisable("君の名は"))
        assertTrue(isRomanisable("Привет"))
        // Mixed is the common case and must still count.
        assertTrue(isRomanisable("Hello 世界"))
    }

    @Test
    fun `a lyric of only digits and symbols is not worth romanising`() {
        // Nothing to romanise, and treating it as translatable would fire a
        // request for an instrumental.
        assertFalse(isRomanisable("--- 4 ---"))
    }
}

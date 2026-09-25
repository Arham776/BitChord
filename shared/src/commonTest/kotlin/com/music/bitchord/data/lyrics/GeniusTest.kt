package com.music.bitchord.data.lyrics

import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Genius: picking the right page, and reading it.
 *
 * The scoring is the interesting part. Genius files a translation, a
 * transcription and a tracklist under the same title as the song, and an
 * unpenalised best-of returns whichever of those sorts first — which for a
 * non-English lyric is reliably a translation into a language the listener does
 * not read.
 */
class GeniusTest {

    // ---- Reading a page ---------------------------------------------------

    private val modernPage = """
        <html><body>
          <div class="song_body">
            <div data-lyrics-container="true">
              <div data-exclude-from-selection="true">46 Contributors</div>
              [Verse 1]<br/>
              I&nbsp;woke up &amp; it was<br/>
              seven in the morning
            </div>
          </div>
          <div class="inread-ad">buy this</div>
        </body></html>
    """.trimIndent()

    @Test
    fun `the marked container is read and nothing around it`() {
        val lines = Genius.parseHtml(modernPage)!!
        val text = lines.joinToString("\n") { it.text }
        assertTrue(text.contains("I woke up & it was"))
        // The contributor count is markup in a container, not a line of the song.
        assertTrue(!text.contains("46 Contributors"))
        // The ad is a sibling and must not leak in.
        assertTrue(!text.contains("buy this"))
    }

    @Test
    fun `an older page with only the class is read too`() {
        val legacy = """
            <html><body><div class="Lyrics-Container">
              one<br/>two
            </div></body></html>
        """.trimIndent()
        val lines = Genius.parseHtml(legacy)!!
        assertEquals(listOf("one", "two"), lines.map { it.text })
    }

    @Test
    fun `a page with no lyric container is a miss rather than a page of markup`() {
        assertEquals(null, Genius.parseHtml("<html><body><p>404 not found</p></body></html>"))
    }

    @Test
    fun `every line is stamped zero`() {
        // Which is the point, not a placeholder: it is how every unsynced source
        // says the same thing, and the panel reads it as words to scroll by hand.
        assertTrue(Genius.parseHtml(modernPage)!!.all { it.timeMs == 0L })
    }

    @Test
    fun `stanza breaks are kept`() {
        val lines = Genius.textToLyricLines("one\n\ntwo\n\n\nthree")
        assertEquals(listOf("one", "", "two", "", "three"), lines.map { it.text })
    }

    @Test
    fun `a gap is never doubled and never at either end`() {
        val lines = Genius.textToLyricLines("\n\none\n\n\ntwo\n\n")
        assertEquals(listOf("one", "", "two"), lines.map { it.text })
    }

    @Test
    fun `page furniture is stripped`() {
        // A trailing "Embed" is the real pattern: it sits at the end of the last
        // line, not in the middle of the song.
        val raw = "real words\u00A0here\u200B\nYou might also like\nmore words 3Embed"
        val cleaned = Genius.stripArtifacts(raw)
        assertTrue(!cleaned.contains("Embed"))
        assertTrue(!cleaned.contains("You might also like"))
        assertTrue(cleaned.contains("real words"))
        assertTrue(cleaned.contains("more words"))
    }

    @Test
    fun `an Embed in the middle of a line is left alone`() {
        // Only the trailing one is furniture. A word that happens to be "Embed"
        // inside the song is part of the song.
        assertTrue(Genius.stripArtifacts("Embed my heart").contains("Embed"))
    }

    // ---- Choosing the page -------------------------------------------------

    private fun candidate(
        title: String,
        artist: String,
        path: String = "/songs/x",
    ): String =
        """{"title":"$title","artist_names":"$artist","path":"$path",""" +
            """"url":"https://genius.com/songs/x"}"""

    private fun parsed(vararg rows: String): List<kotlinx.serialization.json.JsonObject> {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        return rows.map { json.parseToJsonElement(it).jsonObjectCompat() }
    }

    private fun kotlinx.serialization.json.JsonElement.jsonObjectCompat() =
        this as kotlinx.serialization.json.JsonObject

    @Test
    fun `the exact title and artist wins`() {
        val best = Genius.bestMatch(
            parsed(
                candidate("Same Title", "A Different Band"),
                candidate("Same Title", "The Right Band"),
            ),
            targetTitle = "Same Title",
            targetArtist = "The Right Band",
        )
        assertEquals("The Right Band", best?.get("artist_names")?.jsonPrimitiveContent())
    }

    @Test
    fun `a translation is not chosen for an English lyric`() {
        // The path is spelled `/turkce-…` — no diacritics — because that is what
        // Genius's own slugifier produces, and it is the more common form.
        // The failure this whole penalty list exists for: taking the best of an
        // unpenalised set returns the Turkish translation of a song whose lyrics
        // are in English, and nobody can read it.
        val best = Genius.bestMatch(
            parsed(
                candidate("Same Title", "The Right Band", path = "/turkce-adamlar-same-title"),
                candidate("Same Title", "The Right Band", path = "/the-right-band-same-title"),
            ),
            targetTitle = "Same Title",
            targetArtist = "The Right Band",
        )
        assertEquals("/the-right-band-same-title", best?.get("path")?.jsonPrimitiveContent())
    }

    @Test
    fun `a transcription is not chosen for a sung song`() {
        val best = Genius.bestMatch(
            parsed(
                candidate("Song", "The Band", path = "/the-band-song-transkrypcja"),
                candidate("Song", "The Band", path = "/the-band-song-lyrics"),
            ),
            targetTitle = "Song",
            targetArtist = "The Band",
        )
        assertEquals("/the-band-song-lyrics", best?.get("path")?.jsonPrimitiveContent())
    }

    @Test
    fun `a tracklist is not chosen`() {
        val best = Genius.bestMatch(
            parsed(
                candidate("Album", "The Band", path = "/the-band-album-tracklist"),
                candidate("Album", "The Band", path = "/the-band-album-lyrics"),
            ),
            targetTitle = "Album",
            targetArtist = "The Band",
        )
        assertEquals("/the-band-album-lyrics", best?.get("path")?.jsonPrimitiveContent())
    }

    @Test
    fun `a candidate that shares neither title nor artist is not considered at all`() {
        val best = Genius.bestMatch(
            parsed(candidate("Something Else Entirely", "Nobody")),
            targetTitle = "Same Title",
            targetArtist = "The Right Band",
        )
        assertEquals(null, best)
    }

    @Test
    fun `an empty candidate set is a miss`() {
        assertEquals(null, Genius.bestMatch(emptyList(), "a", "b"))
    }

    @Test
    fun `a title that mentions a translation still prefers the translation`() {
        // The penalty is conditional: a song *called* "Translation" must not have
        // its own page penalised.
        val best = Genius.bestMatch(
            parsed(candidate("Translation", "The Band", path = "/the-band-translation")),
            targetTitle = "Translation",
            targetArtist = "The Band",
        )
        assertEquals("/the-band-translation", best?.get("path")?.jsonPrimitiveContent())
    }
}

private fun kotlinx.serialization.json.JsonElement.jsonPrimitiveContent(): String? =
    (this as? kotlinx.serialization.json.JsonPrimitive)?.jsonPrimitive?.content

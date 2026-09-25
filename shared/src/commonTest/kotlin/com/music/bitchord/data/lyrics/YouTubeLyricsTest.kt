package com.music.bitchord.data.lyrics

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The two video-id sources, tested against the response shapes they parse.
 *
 * These are the only sources here that are not guessing — they are asked about
 * the exact video being played — so the risk in them is not a wrong match but a
 * misparse. YouTube renames response keys without notice, which is why the
 * traversal walks rather than following a path, and that walk is what these pin.
 */
class YouTubeLyricsTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    // ---- The video id gate -------------------------------------------------

    @Test
    fun `a real video id is accepted`() {
        assertTrue(isVideoId("dQw4w9WgXcQ"))
        assertTrue(isVideoId("aBc-123_xyz"))
    }

    @Test
    fun `anything else is refused before a request is spent`() {
        // These are called with whatever the queue entry carried, and a local file
        // or a packed source key is not something get_transcript will have
        // anything to say about.
        assertFalse(isVideoId(""))
        assertFalse(isVideoId("short"))
        assertFalse(isVideoId("waytoolongtobevalid"))
        assertFalse(isVideoId("has space!!"))
        assertFalse(isVideoId("src:addon1::track"))
        assertFalse(isVideoId("/Users/someone/track.m4a"))
    }

    // ---- Finding the thing at any depth ------------------------------------

    @Test
    fun `a renderer is found at the top level`() {
        val page = json.parseToJsonElement(
            """{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"a"}]}}}"""
        )
        assertEquals(1, page.objectsNamedCount("musicDescriptionShelfRenderer"))
    }

    @Test
    fun `a renderer is found several levels down`() {
        // The whole reason this is a walk rather than a path: YouTube nests these
        // differently between responses, and a path breaks on a rename. Built by
        // nesting rather than written out because a hand-counted brace is how this
        // fixture was wrong the first time.
        val page = json.parseToJsonElement(
            nest(mapOf("musicDescriptionShelfRenderer" to mapOf("description" to text)))
        )
        assertEquals(1, page.objectsNamedCount("musicDescriptionShelfRenderer"))
    }

    @Test
    fun `a renderer inside an array is found`() {
        val page = json.parseToJsonElement(
            """{"items":[{"a":1},{"tabRenderer":{"x":1}}]}"""
        )
        assertEquals(1, page.objectsNamedCount("tabRenderer"))
    }

    @Test
    fun `a name that is not there is not found`() {
        val page = json.parseToJsonElement("""{"tabRenderer":{"x":1}}""")
        assertEquals(0, page.objectsNamedCount("transcriptCueRenderer"))
    }

    @Test
    fun `a walk does not loop on a deeply nested array`() {
        val page = json.parseToJsonElement("""{"a":[[[{"tabRenderer":{}}]]]}""")
        assertEquals(1, page.objectsNamedCount("tabRenderer"))
    }

    // ---- Reading text out of a response ------------------------------------

    @Test
    fun `a plain text run is read`() {
        val element = json.parseToJsonElement("""{"runs":[{"text":"hello"}]}""")
        assertEquals(listOf("hello"), element.youtubeStrings())
    }

    @Test
    fun `a simpleText node is read`() {
        val element = json.parseToJsonElement("""{"simpleText":"Lyrics"}""")
        assertEquals(listOf("Lyrics"), element.youtubeStrings())
    }

    @Test
    fun `several runs join in order`() {
        val element = json.parseToJsonElement("""{"runs":[{"text":"one "},{"text":"two"}]}""")
        assertEquals(listOf("one ", "two"), element.youtubeStrings())
    }

    @Test
    fun `text is found however deep it is`() {
        val element = json.parseToJsonElement("""{"a":{"b":{"text":"deep"}}}""")
        assertEquals(listOf("deep"), element.youtubeStrings())
    }

    @Test
    fun `numbers in the subtree are not read as words`() {
        // The walk reaches every leaf, and a response is full of numbers that are
        // not lyrics. Reading those as text put a millisecond timestamp into the
        // middle of a line, scrolling in time with the music.
        val element = json.parseToJsonElement("""{"durationMs":342000,"runs":[{"text":"a"}]}""")
        assertEquals(listOf("a"), element.youtubeStrings())
    }

    @Test
    fun `a node with no text reads as nothing rather than throwing`() {
        assertTrue(json.parseToJsonElement("""{"other":1}""").youtubeStrings().isEmpty())
    }
}

/** Counts the matches, so the walk can be asserted without exposing it. */
private fun kotlinx.serialization.json.JsonElement.objectsNamedCount(name: String): Int {
    val found = mutableListOf<JsonObject>()
    fun walk(element: kotlinx.serialization.json.JsonElement) {
        when (element) {
            is JsonObject -> for ((key, value) in element) {
                if (key == name && value is JsonObject) found += value
                walk(value)
            }
            is kotlinx.serialization.json.JsonArray -> element.forEach(::walk)
            else -> Unit
        }
    }
    walk(this)
    return found.size
}

/** Wraps [value] in [depth] distinct container names, so a walk has to descend. */
private fun nest(value: Any, depth: Int = 6): String {
    val names = listOf(
        "musicShelfRenderer", "contents", "musicShelfRenderer",
        "sectionList", "content", "tabRenderer",
    )
    var wrapped: Any = value
    for (name in names.take(depth)) wrapped = mapOf(name to wrapped)
    return "{\"contents\":{\"tabs\":[${toElement(wrapped)}]}}"
}

private fun toElement(value: Any): String = when (value) {
    is Map<*, *> -> value.entries.joinToString(",", prefix = "{", postfix = "}") { (key, entry) ->
        "\"${key}\":${toElement(entry ?: "null")}"
    }
    is List<*> -> value.joinToString(",", prefix = "[", postfix = "]") { toElement(it ?: "null") }
    is String -> "\"$value\""
    else -> "null"
}

private val text = mapOf("runs" to listOf(mapOf("text" to "a")))

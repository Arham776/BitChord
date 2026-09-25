package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.SearchResult
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Reading YouTube Music's promoted search card.
 *
 * The card is the *only* source of a top result — there is no scoring here, on
 * purpose. Google promotes one row at the head of the unfiltered page, and taking
 * its choice is the difference between showing the answer and showing our guess at
 * one.
 *
 * So the tests are about the shape rather than the judgement: which renderer is
 * read, what happens when the same track appears twice, and what a card that is
 * not a track turns into.
 *
 * The fixtures are built with `buildJsonObject` rather than written as strings.
 * They were strings first, and four of them were wrong — a hand-counted brace is
 * a silent failure that reads as a parser bug.
 */
class SearchCardTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun page(body: JsonObject): JsonObject = body

    // ---- Fixtures ---------------------------------------------------------

    /** The `musicThumbnailRenderer` shape both renderers share. */
    private fun thumbnail(square: Boolean = true): JsonObject = buildJsonObject {
        putJsonObject("musicThumbnailRenderer") {
            putJsonObject("thumbnail") {
                put("thumbnails", buildJsonArray {
                    add(buildJsonObject {
                        put("url", JsonPrimitive("https://example.invalid/thumb.jpg"))
                        put("width", JsonPrimitive(544))
                        put("height", JsonPrimitive(if (square) 544 else 320))
                    })
                })
            }
        }
    }

    private fun runs(vararg text: String): JsonObject = buildJsonObject {
        put("runs", buildJsonArray { text.forEach { add(buildJsonObject { put("text", JsonPrimitive(it)) }) } })
    }

    private fun card(
        videoId: String? = "aaaaaaaaaaa",
        title: String = "Shape of You",
        subtitle: String = "Song • 3:53",
        square: Boolean = true,
    ): JsonObject = buildJsonObject {
        putJsonObject("musicCardShelfRenderer") {
            put("thumbnail", thumbnail(square))
            put("title", runs(title))
            put("subtitle", runs("Artist • ", subtitle))
            // Absent when there is no track behind it: a card with no watch
            // endpoint is a browse card, not a track.
            if (videoId != null) {
                putJsonObject("onTap") {
                    putJsonObject("watchEndpoint") { put("videoId", JsonPrimitive(videoId)) }
                }
            }
        }
    }

    private fun row(videoId: String, title: String): JsonObject = buildJsonObject {
        putJsonObject("musicResponsiveListItemRenderer") {
            put("thumbnail", thumbnail(square = true))
            putJsonObject("overlay") {
                putJsonObject("musicItemThumbnailOverlayRenderer") {
                    putJsonObject("content") {
                        putJsonObject("musicPlayButtonRenderer") {
                            putJsonObject("playNavigationEndpoint") {
                                putJsonObject("watchEndpoint") { put("videoId", JsonPrimitive(videoId)) }
                            }
                        }
                    }
                }
            }
            put(
                "flexColumns",
                buildJsonArray {
                    add(flexColumn(title))
                    add(flexColumn("Someone • Song • 3:00"))
                },
            )
        }
    }

    private fun flexColumn(text: String): JsonObject = buildJsonObject {
        putJsonObject("musicResponsiveListItemFlexColumnRenderer") {
            put("text", runs(text))
        }
    }

    private fun browseCard(
        title: String,
        subtitle: String,
        browseId: String,
        pageType: String,
    ): JsonObject = buildJsonObject {
        putJsonObject("musicCardShelfRenderer") {
            put("thumbnail", thumbnail())
            put("title", runs(title))
            put("subtitle", runs(subtitle))
            putJsonObject("onTap") {
                putJsonObject("browseEndpoint") {
                    put("browseId", JsonPrimitive(browseId))
                    putJsonObject("browseEndpointContextSupportedConfigs") {
                        putJsonObject("browseEndpointContextMusicConfig") {
                            put("pageType", JsonPrimitive(pageType))
                        }
                    }
                }
            }
        }
    }

    /** A page with promoted cards and ordinary rows, in one document. */
    private fun searchPage(cards: List<JsonObject>, rows: List<JsonObject> = emptyList()): JsonObject =
        buildJsonObject {
            put("cards", buildJsonArray { cards.forEach { add(it) } })
            put("rows", buildJsonArray { rows.forEach { add(it) } })
        }

    // ---- The card ---------------------------------------------------------

    @Test
    fun `a song card is promoted`() {
        val results = InnertubeParser.parseSearchPage(page(searchPage(listOf(card()))))
        val top = results.first()
        assertTrue(top is SearchResult.TopTrack)
        assertEquals("Shape of You", (top as SearchResult.TopTrack).song.title)
        assertEquals("aaaaaaaaaaa", top.song.videoId)
    }

    @Test
    fun `the promoted card comes before the list`() {
        val body = searchPage(
            cards = listOf(card(), card(videoId = "zzzzzzzzzzz", title = "Other")),
            rows = listOf(row("bbbbbbbbbbb", "A Row")),
        )
        val results = InnertubeParser.parseSearchPage(page(body))
        assertTrue(results.first() is SearchResult.TopTrack)
    }

    @Test
    fun `a card whose artwork is not square is a video and is not promoted`() {
        // The mixed page is music-only, and a music-video upload belongs
        // exclusively to the Videos tab. Promoting one here would put a video in a
        // music search.
        val results = InnertubeParser.parseSearchPage(page(searchPage(listOf(card(square = false)))))
        assertTrue(results.none { it is SearchResult.TopTrack })
    }

    @Test
    fun `a card with no watch endpoint is not a track`() {
        val results = InnertubeParser.parseSearchPage(page(searchPage(listOf(card(videoId = null)))))
        assertTrue(results.none { it is SearchResult.TopTrack })
    }

    @Test
    fun `a card with no title is not promoted`() {
        val results = InnertubeParser.parseSearchPage(page(searchPage(listOf(card(title = "")))))
        assertTrue(results.none { it is SearchResult.TopTrack })
    }

    @Test
    fun `a card with no artwork still promotes`() {
        // Thumbnails are not load-bearing for the promotion; a card whose artwork
        // failed to render must not cost the listener their top result.
        val bare = buildJsonObject {
            putJsonObject("musicCardShelfRenderer") {
                put("title", runs("Shape of You"))
                putJsonObject("onTap") {
                    putJsonObject("watchEndpoint") { put("videoId", JsonPrimitive("aaaaaaaaaaa")) }
                }
            }
        }
        val top = InnertubeParser.parseSearchPage(page(searchPage(listOf(bare)))).first()
        assertTrue(top is SearchResult.TopTrack)
        assertNull((top as SearchResult.TopTrack).song.thumbnailUrl)
    }

    // ---- Deduplication ----------------------------------------------------

    @Test
    fun `a track that is both the card and a row appears once`() {
        // The card's song is the same renderer object the row walk finds, so it
        // has to be claimed first or it appears twice — once as a heading and once
        // in the list.
        val body = searchPage(
            cards = listOf(card()),
            rows = listOf(row("aaaaaaaaaaa", "Shape of You")),
        )
        val results = InnertubeParser.parseSearchPage(page(body))
        assertEquals(0, results.filterIsInstance<SearchResult.Track>().count { it.song.videoId == "aaaaaaaaaaa" })
        assertEquals(1, results.count { it is SearchResult.TopTrack })
    }

    @Test
    fun `two cards for the same track promote it once`() {
        val results = InnertubeParser.parseSearchPage(page(searchPage(listOf(card(), card()))))
        assertEquals(1, results.count { it is SearchResult.TopTrack })
    }

    // ---- The Videos tab ---------------------------------------------------

    @Test
    fun `the videos tab promotes nothing`() {
        // A music-video upload belongs exclusively to Videos — so the card is not
        // read there at all, rather than read and then filtered away.
        val body = searchPage(cards = listOf(card()), rows = listOf(row("ccccccccccc", "A Video")))
        val results = InnertubeParser.parseSearchPage(page(body), includeVideos = true)
        assertTrue(results.none { it is SearchResult.TopTrack })
    }

    // ---- Browse cards -----------------------------------------------------

    @Test
    fun `an artist card becomes a browse row`() {
        val body = searchPage(
            listOf(browseCard("Tame Impala", "Artist", "UCabcdefghijklmnop", "MUSIC_PAGE_TYPE_ARTIST")),
        )
        val browse = InnertubeParser.parseSearchPage(page(body))
            .filterIsInstance<SearchResult.Browse>()
            .firstOrNull()
        assertEquals("Tame Impala", browse?.item?.title)
        assertEquals("UCabcdefghijklmnop", browse?.item?.browseId)
    }

    @Test
    fun `a card that says video is not a browse row`() {
        val body = searchPage(
            listOf(browseCard("Official Video", "Album", "OLAK5uy_x", "MUSIC_PAGE_TYPE_ALBUM")),
        )
        assertEquals(0, InnertubeParser.parseSearchPage(page(body)).size)
    }

    @Test
    fun `a card with no title is not a browse row either`() {
        val body = searchPage(
            listOf(browseCard("", "Album", "OLAK5uy_x", "MUSIC_PAGE_TYPE_ALBUM")),
        )
        assertEquals(0, InnertubeParser.parseSearchPage(page(body)).size)
    }

    // ---- Ordinary results still work --------------------------------------

    @Test
    fun `a page with no card at all is unaffected`() {
        val body = searchPage(
            cards = emptyList(),
            rows = listOf(row("ddddddddddd", "One"), row("eeeeeeeeeee", "Two")),
        )
        val results = InnertubeParser.parseSearchPage(page(body))
        assertEquals(2, results.size)
        assertTrue(results.all { it is SearchResult.Track })
    }

    @Test
    fun `an empty page is empty rather than an error`() {
        assertEquals(0, InnertubeParser.parseSearchPage(page(searchPage(emptyList()))).size)
    }
}

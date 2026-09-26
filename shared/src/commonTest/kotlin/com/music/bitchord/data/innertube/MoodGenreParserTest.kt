package com.music.bitchord.data.innertube

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `parseMoodAndGenres`, against the shape the real response actually has.
 *
 * The live harness (`scripts/check-moods.sh`) is what proves the *server* still
 * sends this; these fixtures pin the decisions the parser makes about a body it
 * is given, which is the part that has to stay put when the response is refitted.
 *
 * Built with `buildJsonObject` rather than written as JSON text, so a fixture
 * change is a type change and a typo is a compile error rather than a test that
 * quietly asserts nothing.
 */
class MoodGenreParserTest {

    // ---- Fixture builders ---------------------------------------------------

    private fun runs(vararg text: String): JsonObject = buildJsonObject {
        put("runs", buildJsonArray { text.forEach { add(buildJsonObject { put("text", JsonPrimitive(it)) }) } })
    }

    private fun button(
        label: String,
        browseId: String? = "UCm9vYbWTP3J5Y3JxkQ5Yg",
        params: String? = "ggMIJRwbGF6b3VyZRoBVA%3D%3D",
        endpointKey: String = "clickCommand",
    ): JsonObject = buildJsonObject {
        put("musicNavigationButtonRenderer", buildJsonObject {
            put("buttonText", runs(label))
            put(
                endpointKey,
                buildJsonObject {
                    put("browseEndpoint", buildJsonObject {
                        browseId?.let { put("browseId", JsonPrimitive(it)) }
                        params?.let { put("params", JsonPrimitive(it)) }
                    })
                },
            )
        })
    }

    private fun grid(title: String, vararg items: JsonObject): JsonObject = buildJsonObject {
        put("gridRenderer", buildJsonObject {
            put("header", buildJsonObject {
                put("gridHeaderRenderer", buildJsonObject { put("title", runs(title)) })
            })
            put("items", buildJsonArray { items.forEach { add(it) } })
        })
    }

    private fun response(vararg sections: JsonObject): JsonObject = buildJsonObject {
        put("contents", buildJsonObject {
            put("singleColumnBrowseResultsRenderer", buildJsonObject {
                put("tabs", buildJsonArray {
                    add(buildJsonObject {
                        put("tabRenderer", buildJsonObject {
                            put("content", buildJsonObject {
                                put("sectionListRenderer", buildJsonObject {
                                    put("contents", buildJsonArray { sections.forEach { add(it) } })
                                })
                            })
                        })
                    })
                })
            })
        })
    }

    // ---- Tests --------------------------------------------------------------

    @Test
    fun a_grid_becomes_a_named_section_of_buttons() {
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("Moods & moments", button("Chill"), button("Focus")))
        )
        assertEquals(1, parsed.size)
        assertEquals("Moods & moments", parsed[0].title)
        assertEquals(listOf("Chill", "Focus"), parsed[0].items.map { it.title })
    }

    @Test
    fun a_button_keeps_the_browse_id_and_the_params() {
        // Params travel with the id rather than being folded into it: a category
        // browsed without them answers with a different, generic page rather than
        // an error, so losing them looks like a working feature returning the
        // wrong thing.
        val parsed = InnertubeParser.parseMoodAndGenres(response(grid("Genres", button("Blues"))))
        val item = parsed[0].items[0]
        assertEquals("UCm9vYbWTP3J5Y3JxkQ5Yg", item.browseId)
        assertEquals("ggMIJRwbGF6b3VyZRoBVA%3D%3D", item.params)
    }

    @Test
    fun a_button_without_params_keeps_a_null_rather_than_an_empty_string() {
        // Null and "" are different requests. A category the server sent without
        // params must not acquire a blank one on the way through, or the browse
        // sends `params: ""` and asks for something the server has to refuse.
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("Genres", button("Blues", params = null)))
        )
        assertNull(parsed[0].items[0].params)
    }

    @Test
    fun a_navigation_endpoint_is_used_when_there_is_no_click_command() {
        // Some responses carry only the one. Without the fallback a whole section
        // can come back empty against a body that plainly describes it.
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("Moods", button("Chill", endpointKey = "navigationEndpoint")))
        )
        assertEquals(listOf("Chill"), parsed[0].items.map { it.title })
    }

    @Test
    fun a_click_command_wins_over_a_navigation_endpoint() {
        // The button was built to do the click. Reading the passive endpoint
        // first would follow wherever the card happened to point.
        val both = buildJsonObject {
            put("musicNavigationButtonRenderer", buildJsonObject {
                put("buttonText", runs("Chill"))
                put("navigationEndpoint", buildJsonObject {
                    put("browseEndpoint", buildJsonObject { put("browseId", JsonPrimitive("WRONG")) })
                })
                put("clickCommand", buildJsonObject {
                    put("browseEndpoint", buildJsonObject { put("browseId", JsonPrimitive("RIGHT")) })
                })
            })
        }
        val parsed = InnertubeParser.parseMoodAndGenres(response(grid("Moods", both)))
        assertEquals("RIGHT", parsed[0].items[0].browseId)
    }

    @Test
    fun a_button_with_no_browse_endpoint_is_not_offered() {
        // Nothing to navigate to, so it is not a category — offering it would
        // produce a tile that goes nowhere when tapped.
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("Moods", button("Chill", browseId = null)))
        )
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun a_button_with_no_label_is_not_offered() {
        // A tile with no text is a picture with nothing to say. The live
        // response has no such button, so this is a guard against a future
        // renderer being read as a category.
        val unlabelled = buildJsonObject {
            put("musicNavigationButtonRenderer", buildJsonObject {
                put("clickCommand", buildJsonObject {
                    put("browseEndpoint", buildJsonObject { put("browseId", JsonPrimitive("UC_x5XG1OV2P6uZZ5FSM9Ttw")) })
                })
            })
        }
        val parsed = InnertubeParser.parseMoodAndGenres(response(grid("Moods", unlabelled)))
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun a_blank_label_is_not_offered() {
        val blank = buildJsonObject {
            put("musicNavigationButtonRenderer", buildJsonObject {
                put("buttonText", runs("   "))
                put("clickCommand", buildJsonObject {
                    put("browseEndpoint", buildJsonObject { put("browseId", JsonPrimitive("UC_x5XG1OV2P6uZZ5FSM9Ttw")) })
                })
            })
        }
        val parsed = InnertubeParser.parseMoodAndGenres(response(grid("Moods", blank)))
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun a_section_with_no_buttons_is_dropped() {
        // An empty grid is a hole in the page with a heading above it.
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("Moods & moments", button("Chill")), grid("Genres"))
        )
        assertEquals(listOf("Moods & moments"), parsed.map { it.title })
    }

    @Test
    fun a_section_with_no_heading_is_dropped() {
        // The heading is what makes the buttons mean anything: "Moods" and
        // "Genres" are different sets and an unlabelled grid is neither.
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(grid("", button("Chill"), button("Focus")))
        )
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun a_section_that_is_not_a_grid_is_left_alone() {
        // A fixed path, not a walk. A walk would pick up any nested gridRenderer
        // on a browse response and call it a mood, which is how a page ends up
        // offering "for you" as a category.
        val notAGrid = buildJsonObject {
            put("musicShelfRenderer", buildJsonObject { put("title", runs("Albums")) })
        }
        val parsed = InnertubeParser.parseMoodAndGenres(response(notAGrid))
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun an_empty_response_yields_nothing_rather_than_throwing() {
        val parsed = InnertubeParser.parseMoodAndGenres(buildJsonObject {})
        assertEquals(emptyList(), parsed)
    }

    @Test
    fun sections_keep_the_order_the_server_sent_them_in() {
        val parsed = InnertubeParser.parseMoodAndGenres(
            response(
                grid("Moods & moments", button("Chill")),
                grid("Genres", button("Blues"), button("Jazz")),
            )
        )
        assertEquals(listOf("Moods & moments", "Genres"), parsed.map { it.title })
        assertEquals(2, parsed[1].items.size)
    }

    @Test
    fun every_button_in_a_section_is_kept() {
        // Twenty-four genres in the live response. A cap here would be a silent
        // truncation of the server's own list.
        val many = (1..24).map { button("Genre $it") }.toTypedArray()
        val parsed = InnertubeParser.parseMoodAndGenres(response(grid("Genres", *many)))
        assertEquals(24, parsed[0].items.size)
        assertTrue(parsed[0].items.last().title == "Genre 24")
    }
}

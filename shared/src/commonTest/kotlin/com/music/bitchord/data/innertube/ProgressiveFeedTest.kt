package com.music.bitchord.data.innertube

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlin.test.*

class ProgressiveFeedTest {
    private fun page(title: String) = Json.parseToJsonElement("""{
        "musicCarouselShelfRenderer": {
            "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"$title"}]}}},
            "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Album"}]},
            "navigationEndpoint":{"browseEndpoint":{"browseId":"MPRE-fixture"}}}}]
        }}""") as kotlinx.serialization.json.JsonObject

    @Test fun primaryHomeAppearsWithoutWaitingForSupplements() = runTest {
        Innertube.cookie = null
        val times = mutableListOf<Long>()
        val titles = mutableListOf<List<String>>()
        HomeBridge.progressiveFeed(true, Innertube.sessionGeneration, publish = { feed, _ ->
            times += testScheduler.currentTime
            titles += feed.shelves.map { it.title }
        }, browse = { id ->
            delay(if (id == "FEmusic_home") 50 else 500)
            page(id)
        })
        assertEquals(50L, times.first())
        assertEquals(500L, times.last())
        assertEquals(listOf("FEmusic_home"), titles.first())
        assertEquals(listOf("FEmusic_home", "FEmusic_new_releases", "FEmusic_explore"), titles.last())
    }
    @Test fun exploreAndChartsRunConcurrently() = runTest {
        Innertube.cookie = null
        val times = mutableListOf<Long>()
        HomeBridge.progressiveFeed(false, Innertube.sessionGeneration, publish = { _, _ -> times += testScheduler.currentTime },
            browse = { id -> delay(if (id == "FEmusic_explore") 50 else 300); page(id) })
        assertEquals(listOf(50L, 300L), times)
    }
    @Test fun supplementalFailureRetainsPrimaryFeed() = runTest {
        Innertube.cookie = null
        val results = mutableListOf<Pair<List<String>, Boolean>>()
        HomeBridge.progressiveFeed(false, Innertube.sessionGeneration, publish = { feed, complete -> results += feed.shelves.map { it.title } to complete },
            browse = { if (it == "FEmusic_charts") error("offline") else page("Primary") })
        assertEquals(listOf("Primary"), results.last().first)
        assertTrue(results.last().second)
    }
    @Test fun accountSwitchDiscardsFeed() = runTest {
        Innertube.cookie = null
        val generation = Innertube.sessionGeneration
        try {
            assertFailsWith<Innertube.SessionChangedException> {
                HomeBridge.progressiveFeed(false, generation, publish = { _, _ -> fail("Obsolete feed was published") }, browse = {
                    Innertube.cookie = "SAPISID=new-account"
                    page("Obsolete")
                })
            }
        } finally { Innertube.cookie = null }
    }
}

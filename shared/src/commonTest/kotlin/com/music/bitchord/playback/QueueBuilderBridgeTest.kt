package com.music.bitchord.playback

import com.music.bitchord.data.settings.AppSettings
import kotlinx.serialization.json.*
import kotlin.test.*

class QueueBuilderBridgeTest {
    @Test fun freshRecommendationsCanReuseUnplayedSuggestionsButExcludePlayedAndManualSongs() {
        val old = AppSettings.dontRepeatSuggestions.value
        try {
            AppSettings.setDontRepeatSuggestions(true)
            QueueBuilderBridge.clearSession()
            val kept = """[{"videoId":"seed","title":"Seed","artist":"Seed Artist"},{"videoId":"manual","title":"Manual","artist":"Manual Artist"}]"""
            val candidates = """[{"videoId":"manual","title":"Manual","artist":"Manual Artist"},{"videoId":"fresh","title":"Fresh","artist":"New Artist"},{"videoId":"fresh-copy","title":"Fresh (Official Audio)","artist":"New Artist"}]"""
            fun ids(json: String) = Json.parseToJsonElement(json).jsonArray.map { it.jsonObject.getValue("videoId").jsonPrimitive.content }
            assertEquals(listOf("fresh"), ids(QueueBuilderBridge.extendJson(kept, candidates, 8)))
            assertEquals(listOf("fresh"), ids(QueueBuilderBridge.extendJson(kept, candidates, 8)))
            QueueBuilderBridge.rememberPlayed("fresh")
            assertEquals(listOf("fresh-copy"), ids(QueueBuilderBridge.extendJson(kept, candidates, 8)))
            // Played recordings in the queue prefix also exclude alternate IDs.
            val playedPrefix = """[{"videoId":"fresh","title":"Fresh","artist":"New Artist"}]"""
            assertEquals(listOf("manual"), ids(QueueBuilderBridge.extendJson(playedPrefix, candidates, 8)))
        } finally {
            QueueBuilderBridge.clearSession()
            AppSettings.setDontRepeatSuggestions(old)
        }
    }
}

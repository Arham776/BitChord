package com.music.bitchord.data.innertube

import kotlinx.serialization.json.*
import kotlin.test.*

class PlaybackDurationBridgeTest {
    @Test fun durationSurvivesThePlaybackPayload() {
        val payload = PlayerBridge.StreamPayload("https://media.invalid/audio", 160, "audio/webm", durationSeconds = 245)
        val encoded = Json.encodeToString(PlayerBridge.StreamPayload.serializer(), payload)
        assertEquals(245, Json.parseToJsonElement(encoded).jsonObject["durationSeconds"]?.jsonPrimitive?.int)
        assertEquals(245L, Json.decodeFromString(PlayerBridge.StreamPayload.serializer(), encoded).durationSeconds)
    }
    @Test fun olderPayloadsWithoutDurationRemainValid() {
        val payload = Json.decodeFromString(PlayerBridge.StreamPayload.serializer(), """{"url":"https://media.invalid/audio","kbps":160,"mimeType":"audio/webm"}""")
        assertNull(payload.durationSeconds)
    }
}

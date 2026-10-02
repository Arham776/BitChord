package com.music.bitchord.data.innertube

import kotlin.test.Test
import kotlin.test.assertEquals

class PlaybackTokenBridgeTest {
    @Test fun tokensUseUpstreamBindingsRatherThanTheirMisleadingNames() {
        val result = PlaybackTokenBridge.mapTokens("visitor identity", "video-bound token", "visitor-bound token")
        assertEquals("visitor-bound token", result.playerRequestToken)
        assertEquals("video-bound token", result.streamingDataToken)
        assertEquals("visitor identity", result.visitorData)
    }
}

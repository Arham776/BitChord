package com.music.bitchord.data.innertube

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AudioRenditionTest {
    private val response = Json.parseToJsonElement("""
        {"streamingData":{"adaptiveFormats":[
          {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,"url":"https://example.com/aac"},
          {"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","bitrate":160000,"url":"https://example.com/opus"},
          {"itag":141,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":256000,"url":"https://example.com/high"}
        ]}}
    """).jsonObject

    @Test fun opusIsPlayableAndRankedByCodecTier() {
        assertEquals(listOf("https://example.com/opus", "https://example.com/aac"), StreamResolver.rankForPlayback(response, 192, false).map { it.url })
    }
    @Test fun dataCeilingAppliesEvenWhenCipherSolverIsBroken() {
        for (broken in listOf(false, true)) {
            val result = StreamResolver.rankForPlayback(response, 128, broken)
            assertEquals(listOf("https://example.com/aac"), result.map { it.url })
            assertTrue(StreamResolver.rankForPlayback(response, 64, broken).isEmpty())
        }
    }
}

package com.music.bitchord.data.sources

import com.music.bitchord.data.model.Song
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class NativeDecoderFormatTest {

    @Test
    fun `Opus is eligible now that the native decoder includes libopus`() {
        assertFalse(StreamFormat(codec = "opus").isKnownUnsupportedByNativeDecoder)
        assertFalse(StreamFormat(codec = "webm").isKnownUnsupportedByNativeDecoder)
    }

    @Test
    fun `known unsupported codecs do not win source resolution`() {
        listOf(
            "ape",
            "wavpack",
            "audio/x-wavpack",
            "dsf",
            "audio/dff",
            "eac3-joc",
            "audio/e-ac-3",
            "audio/ec3-joc",
            "audio/mp4; codecs=\"ec-3\"",
            "dolby-atmos",
            "audio/vnd.dts.hd",
            "audio/true-hd",
            "audio/x-ms-wma",
            "mpc",
            "wma",
            "truehd",
        ).forEach { codec ->
            assertTrue(
                StreamFormat(codec = codec).isKnownUnsupportedByNativeDecoder,
                "$codec must fall through to a playable source",
            )
        }
    }

    @Test
    fun `unknown codec claims remain probeable`() {
        assertFalse(StreamFormat(codec = "application/x-bit-chord-audio").isKnownUnsupportedByNativeDecoder)
        assertFalse(StreamFormat().isKnownUnsupportedByNativeDecoder)
    }

    @Test
    fun `lossless and Atmos aliases are normalized before ranking`() {
        assertTrue(StreamFormat(codec = "audio/flac").isLossless == true)
        assertTrue(StreamFormat(codec = "audio/wav").isLossless == true)
        assertTrue(StreamFormat(codec = "audio/eac3-joc").isDolbyAtmos)
    }

    @Test
    fun `resolver skips an unsupported stream and takes a playable provider`() = runTest {
        val unsupported = TestMusicSource(
            configId = "unsupported",
            streamFormat = StreamFormat(codec = "audio/e-ac-3"),
        )
        val playable = TestMusicSource(
            configId = "playable",
            streamFormat = StreamFormat(codec = "aac"),
        )

        val result = SourceResolver.bestAcross(
            sources = listOf(unsupported, playable),
            target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam", 300),
            request = StreamRequest.Best,
        )

        assertNotNull(result)
        assertEquals("playable", result.first.configId)
        assertEquals("aac", result.second.format.codec)
    }
}

private class TestMusicSource(
    override val configId: String,
    private val streamFormat: StreamFormat,
) : MusicSource {
    override val kind: SourceKind = SourceKind.ADDON
    override val displayName: String = configId

    override suspend fun health(): SourceHealth = SourceHealth.Ok()

    override suspend fun search(
        query: String,
        limit: Int,
        waitForAll: Boolean,
        request: StreamRequest?,
    ): List<Song> = listOf(
        Song(videoId = configId, title = "Paniyon Sa", artist = "Atif Aslam", durationText = "5:00"),
    )

    override suspend fun stream(trackId: String, request: StreamRequest): SourceStream =
        SourceStream(url = "https://example.test/$trackId", format = streamFormat)
}

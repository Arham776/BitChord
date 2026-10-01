package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.ProbeResult
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.*

class StreamResolverRecoveryTest {
    private suspend fun fixture(body: suspend () -> Unit) {
        val player = Innertube.playerTransport
        val probe = StreamResolver.streamProbe
        val timestamp = StreamResolver.timestampProvider
        val transform = StreamResolver.urlTransform
        try {
            Innertube.cookie = null
            Innertube.adoptSessionScope(null, null, null, "synthetic-visitor", null, false)
            StreamResolver.onSessionChanged()
            StreamResolver.timestampProvider = { 12345 }
            StreamResolver.urlTransform = { it }
            body()
        } finally {
            Innertube.playerTransport = player
            StreamResolver.streamProbe = probe
            StreamResolver.timestampProvider = timestamp
            StreamResolver.urlTransform = transform
            Innertube.cookie = null
            StreamResolver.onSessionChanged()
        }
    }
    private fun id(request: Innertube.MusicRequest) =
        Json.parseToJsonElement(request.body).jsonObject["videoId"]!!.jsonPrimitive.content
    private fun formats(vararg entries: Pair<String, Int>): String =
        """{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[${entries.joinToString(",") { (url, rate) ->
            """{"url":"$url","mimeType":"audio/mp4","bitrate":${rate * 1000}}"""
        }}]}}"""
    private fun empty() = formats()

    @Test fun refusedBestFormatDoesNotDiscardPlayableLowerRendition() = runTest {
        fixture {
            val probed = mutableListOf<String>()
            Innertube.playerTransport = { formats("https://media.invalid/high" to 192, "https://media.invalid/low" to 128) }
            StreamResolver.streamProbe = { url, _ ->
                probed += url
                ProbeResult(if (url.endsWith("high")) 403 else 206, "audio/mp4", true)
            }
            val stream = assertNotNull(StreamResolver.resolve("ladder"))
            assertEquals("https://media.invalid/low", stream.url)
            assertEquals(listOf("https://media.invalid/high", "https://media.invalid/low"), probed)
        }
    }
    @Test fun directUrlIsTransformedBeforeItIsProbedAndCached() = runTest {
        fixture {
            Innertube.playerTransport = { formats("https://media.invalid/audio?n=original" to 128) }
            var transforms = 0
            StreamResolver.urlTransform = { transforms++; it.replace("original", "solved") }
            StreamResolver.streamProbe = { url, _ ->
                assertTrue(url.endsWith("n=solved"))
                ProbeResult(206, "audio/mp4", true)
            }
            assertEquals("https://media.invalid/audio?n=solved", StreamResolver.resolve("transform")!!.url)
            assertEquals("https://media.invalid/audio?n=solved", StreamResolver.resolve("transform")!!.url)
            assertEquals(1, transforms)
        }
    }
    @Test fun manyDeadTrackUrlsDoNotDisableNextOrBackForTheSession() = runTest {
        fixture {
            var refusing = true
            var androidRequests = 0
            Innertube.playerTransport = {
                if (it.headers["X-YouTube-Client-Name"] == PlayerClient.ANDROID.clientId) {
                    androidRequests++
                    formats("https://media.invalid/${id(it)}" to 128)
                } else empty()
            }
            StreamResolver.streamProbe = { _, _ -> ProbeResult(if (refusing) 403 else 206, "audio/mp4", !refusing) }
            // The reported sequence: rapid selections run into several CDN
            // refusals, then a previously good song and Back both stop resolving.
            repeat(9) { assertFailsWith<IllegalStateException> { StreamResolver.resolve("failed-$it") } }
            refusing = false
            assertNotNull(StreamResolver.resolve("next-good"))
            assertNotNull(StreamResolver.resolve("failed-0"))
            assertEquals(20, androidRequests, "Each failed guest selection gets at most one fresh read; Next and Back remain usable")
        }
    }
    @Test fun refusedGuestUrlGetsOneFreshPlayerReadInsteadOfTheSameUrl() = runTest {
        fixture {
            var reads = 0
            Innertube.playerTransport = {
                if (it.headers["X-YouTube-Client-Name"] == PlayerClient.ANDROID.clientId) {
                    reads++
                    formats("https://media.invalid/${if (reads == 1) "dead" else "fresh"}" to 128)
                } else empty()
            }
            StreamResolver.streamProbe = { url, _ -> ProbeResult(if (url.endsWith("dead")) 403 else 206, "audio/mp4", true) }
            assertEquals("https://media.invalid/fresh", StreamResolver.resolve("refresh-url")!!.url)
            assertEquals(2, reads)
        }
    }
    @Test fun anonymousVerdictDoesNotSuppressResolvedSignedInDeviceFallback() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=synthetic-only"
            Innertube.adoptSessionScope(null, "chosen-channel", "4", "synthetic-visitor", null, true)
            var authenticatedRequests = 0
            Innertube.playerTransport = {
                if (it.headers["Cookie"] == null) {
                    assertNull(it.headers["Authorization"])
                    """{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age"}}"""
                } else {
                    authenticatedRequests++
                    assertEquals("4", it.headers["X-Goog-AuthUser"])
                    assertTrue(it.body.contains("chosen-channel"))
                    assertEquals("https://www.youtube.com/youtubei/v1/player", it.url)
                    assertTrue(it.headers["Authorization"]!!.startsWith("SAPISIDHASH "))
                    formats("https://media.invalid/signed-in" to 128)
                }
            }
            StreamResolver.streamProbe = { _, headers ->
                assertNull(headers["Cookie"])
                assertNull(headers["Authorization"])
                ProbeResult(206, "audio/mp4", true)
            }
            repeat(4) { assertNotNull(StreamResolver.resolve("gated-$it")) }
            assertEquals(4, authenticatedRequests)
        }
    }
    @Test fun identicalConcurrentSelectionsShareOnePlayerWalk() = runTest {
        fixture {
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val lock = Mutex()
            var calls = 0
            Innertube.playerTransport = {
                lock.withLock { calls++ }
                entered.complete(Unit)
                release.await()
                formats("https://media.invalid/coalesced" to 128)
            }
            StreamResolver.streamProbe = { _, _ -> ProbeResult(206, "audio/mp4", true) }
            val selections = List(10) { async { StreamResolver.resolve("same-next") } }
            entered.await()
            runCurrent()
            release.complete(Unit)
            selections.awaitAll().forEach { assertNotNull(it) }
            assertEquals(1, lock.withLock { calls })
        }
    }
    @Test fun signedMediaUrlAndItsActualIdentityArePreserved() = runTest {
        fixture {
            val url = "https://r.googlevideo.com/media?c=WEB&cver=2.20260708.00.00&signature=fixture"
            Innertube.playerTransport = { formats(url to 128) }
            StreamResolver.streamProbe = { received, headers ->
                assertEquals(url, received)
                assertEquals(PlayerClient.WEB.userAgent, headers["User-Agent"])
                assertEquals("https://www.youtube.com", headers["Origin"])
                ProbeResult(206, "audio/mp4", true)
            }
            assertEquals(url, StreamResolver.resolve("minted-web")!!.url)
        }
    }
    @Test fun playbackTailRefusalInvalidatesOnlyItsUrlAndNextStillResolves() = runTest {
        fixture {
            var requests = 0
            Innertube.playerTransport = {
                requests++
                formats("https://r.googlevideo.com/${id(it)}?c=ANDROID&attempt=$requests" to 128)
            }
            StreamResolver.streamProbe = { _, _ -> ProbeResult(206, "audio/mp4", true) }
            val original = StreamResolver.resolve("tail-refused")!!
            StreamResolver.onPlaybackRefused(original.url, 403)
            assertNotNull(StreamResolver.resolve("following-track"))
            assertNotEquals(original.url, StreamResolver.resolve("tail-refused")!!.url)
            assertEquals(3, requests)
        }
    }
}

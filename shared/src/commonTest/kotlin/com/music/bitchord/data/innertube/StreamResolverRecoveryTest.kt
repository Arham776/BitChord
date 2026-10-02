package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.ProbeResult
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

/** The production resolver shell around upstream extraction, with synthetic media. */
class StreamResolverRecoveryTest {
    private suspend fun fixture(body: suspend () -> Unit) {
        val extract = StreamResolver.extraction
        val probe = StreamResolver.streamProbe
        try {
            Innertube.cookie = null
            StreamResolver.onSessionChanged()
            StreamResolver.streamProbe = { _, _ -> ProbeResult(206, "audio/mp4", true) }
            body()
        } finally {
            StreamResolver.extraction = extract; StreamResolver.streamProbe = probe
            Innertube.cookie = null; StreamResolver.onSessionChanged()
        }
    }
    private fun stream(id: String) = StreamResolver.ResolvedStream(
        "https://media.invalid/$id", 128, "audio/mp4", mapOf("User-Agent" to "synthetic-profile"))

    @Test fun rejectedMediaGetsFreshExtractionWithoutReplayingDeadUrl() = runTest {
        fixture {
            var attempts = 0
            val probes = mutableListOf<String>()
            StreamResolver.extraction = { _, _ -> stream(if (++attempts == 1) "dead" else "fresh") }
            StreamResolver.streamProbe = { url, headers ->
                assertEquals("synthetic-profile", headers["User-Agent"])
                probes += url; ProbeResult(if (url.endsWith("dead")) 403 else 206, "audio/mp4", true)
            }
            assertTrue(StreamResolver.resolve("track")!!.url.endsWith("fresh"))
            assertEquals(2, attempts)
            assertEquals(listOf("https://media.invalid/dead", "https://media.invalid/fresh"), probes)
        }
    }
    @Test fun refusalRecoveryIsBoundedAndDoesNotDisableOtherTracks() = runTest {
        fixture {
            var attempts = 0
            StreamResolver.extraction = { id, _ -> attempts++; stream(id) }
            StreamResolver.streamProbe = { url, _ -> ProbeResult(if (url.endsWith("bad")) 403 else 206, "audio/mp4", true) }
            assertFailsWith<IllegalStateException> { StreamResolver.resolve("bad") }
            assertEquals(3, attempts)
            assertNotNull(StreamResolver.resolve("good"))
            assertEquals(4, attempts)
        }
    }
    @Test fun duplicateRequestsShareOneExtraction() = runTest {
        fixture {
            var requests = 0
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            StreamResolver.extraction = { id, _ -> requests++; entered.complete(Unit); release.await(); stream(id) }
            val first = async { StreamResolver.resolve("shared") }
            entered.await()
            val second = async { StreamResolver.resolve("shared") }
            yield(); release.complete(Unit)
            assertEquals(first.await(), second.await()); assertEquals(1, requests)
        }
    }
    @Test fun cancellingOneListenerDoesNotCancelAnother() = runTest {
        fixture {
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            StreamResolver.extraction = { id, _ -> entered.complete(Unit); release.await(); stream(id) }
            val first = async { StreamResolver.resolve("shared") }; entered.await()
            val second = async { StreamResolver.resolve("shared") }; yield()
            first.cancelAndJoin(); release.complete(Unit)
            assertNotNull(second.await())
        }
    }
    @Test fun abandonedSelectionCancelsItsExtraction() = runTest {
        fixture {
            val entered = CompletableDeferred<Unit>(); val cancelled = CompletableDeferred<Unit>()
            StreamResolver.extraction = { _, _ ->
                try { entered.complete(Unit); awaitCancellation() }
                finally { cancelled.complete(Unit) }
            }
            val selection = async { StreamResolver.resolve("abandoned") }; entered.await()
            selection.cancelAndJoin(); withContext(Dispatchers.Default) { withTimeout(3000) { cancelled.await() } }
        }
    }
    @Test fun accountSwitchRejectsObsoleteResponseAndDoesNotRetainIt() = runTest {
        fixture {
            StreamResolver.extraction = { id, _ ->
                Innertube.cookie = "SAPISID=synthetic-new-account"; stream(id)
            }
            assertFailsWith<CancellationException> { StreamResolver.resolve("switch") }
            StreamResolver.extraction = { id, _ -> stream("new-$id") }
            assertTrue(StreamResolver.resolve("switch")!!.url.endsWith("new-switch"))
        }
    }
    @Test fun tailRefusalInvalidatesOnlyIssuedTrackUrl() = runTest {
        fixture {
            var reads = 0
            StreamResolver.extraction = { id, _ -> stream("$id-${++reads}") }
            val original = StreamResolver.resolve("track")!!
            val other = StreamResolver.resolve("other")!!
            StreamResolver.onPlaybackRefused(original.url, 403)
            assertEquals(other, StreamResolver.resolve("other"))
            assertNotEquals(original.url, StreamResolver.resolve("track")!!.url)
            assertEquals(3, reads)
        }
    }
    @Test fun bitrateRequestsAreNotCoalescedAcrossDifferentCeilings() = runTest {
        fixture {
            val ceilings = mutableListOf<Int>()
            StreamResolver.extraction = { id, ceiling -> ceilings += ceiling; stream("$id-$ceiling") }
            assertNotEquals(StreamResolver.resolve("quality", 64), StreamResolver.resolve("quality", Int.MAX_VALUE))
            assertEquals(listOf(64, Int.MAX_VALUE), ceilings)
        }
    }
}

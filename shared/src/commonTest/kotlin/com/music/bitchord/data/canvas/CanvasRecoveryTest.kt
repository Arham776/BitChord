package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.HttpStatusException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class CanvasRecoveryTest {
    private fun art(url: String = "https://video.invalid/cover.mp4") = CanvasArtworkDto(url, source = "community")

    @Test fun typedUnauthorizedRefreshesProviderTokenOnce() = runTest {
        var current = "rejected"
        val sent = mutableListOf<String>()
        val rejected = mutableListOf<String>()
        val body = readCanvasCatalog(token = { current }, reject = { rejected += it; current = "fresh" }) {
            sent += it
            if (it == "rejected") throw HttpStatusException(401)
            "catalog"
        }
        assertEquals("catalog", body)
        assertEquals(listOf("rejected", "fresh"), sent)
        assertEquals(listOf("rejected"), rejected)
    }

    @Test fun repeatedUnauthorizedIsBounded() = runTest {
        var requests = 0
        var rejects = 0
        assertNull(readCanvasCatalog(token = { "token-$rejects" }, reject = { rejects++ }) {
            requests++; throw HttpStatusException(401)
        })
        assertEquals(2, requests)
        assertEquals(2, rejects)
    }

    @Test fun serverAndNetworkFailuresDoNotDiscardCredentials() = runTest {
        for (error in listOf(HttpStatusException(503), IllegalStateException("offline"))) {
            var requests = 0
            var rejects = 0
            assertNull(readCanvasCatalog(token = { "saved" }, reject = { rejects++ }) {
                requests++; throw error
            })
            assertEquals(1, requests)
            assertEquals(0, rejects)
        }
    }

    @Test fun cancellationDoesNotBecomeAProviderMiss() = runTest {
        assertFailsWith<CancellationException> {
            readCanvasCatalog(token = { "saved" }, reject = { error("must not reject") }) {
                throw CancellationException("selection changed")
            }
        }
    }

    @Test fun identicalLookupsCoalesceWhileAnotherSongCanFinish() = runTest {
        val cache = CanvasLookupCache(backgroundScope)
        val release = CompletableDeferred<Unit>()
        var requests = 0
        val first = async { cache.resolve("song") { requests++; release.await(); art() } }
        val second = async { cache.resolve("song") { error("duplicate provider request") } }
        runCurrent()
        assertEquals(1, requests)
        val other = async { cache.resolve("other") { art("https://video.invalid/other.mp4") } }
        runCurrent()
        assertTrue(other.isCompleted, "A slow old song must not hold the cache lock during provider requests")
        release.complete(Unit)
        assertEquals(first.await(), second.await())
    }

    @Test fun offlineMissExpiresAndTheSameSongCanRecover() = runTest {
        var time = 0L
        var requests = 0
        val cache = CanvasLookupCache(backgroundScope, now = { time })
        assertNull(cache.resolve("song") { requests++; null })
        assertNull(cache.resolve("song") { error("Miss should be briefly coalesced") })
        time = 30_000
        assertNotNull(cache.resolve("song") { requests++; art() })
        assertEquals(2, requests)
    }

    @Test fun cachedSignedUrlsExpireAndRefresh() = runTest {
        var time = 0L
        val cache = CanvasLookupCache(backgroundScope, now = { time })
        val old = art("https://video.invalid/old.mp4")
        assertEquals(old, cache.resolve("song") { old })
        time = 30 * 60 * 1000 - 1
        assertEquals(old, cache.resolve("song") { error("still fresh") })
        time++
        val fresh = art("https://video.invalid/fresh.mp4")
        assertEquals(fresh, cache.resolve("song") { fresh })
    }

    @Test fun differentAlbumLookupsKeepSeparateResultsAndLruIsBounded() = runTest {
        val cache = CanvasLookupCache(backgroundScope, capacity = 2)
        val standard = art("https://video.invalid/standard.mp4")
        val deluxe = art("https://video.invalid/deluxe.mp4")
        assertEquals(standard, cache.resolve("song|album=standard") { standard })
        assertEquals(deluxe, cache.resolve("song|album=deluxe") { deluxe })
        assertEquals(standard, cache.resolve("song|album=standard") { error("reuse") })
        cache.resolve("third") { art() }
        var reloaded = false
        cache.resolve("song|album=deluxe") { reloaded = true; deluxe }
        assertTrue(reloaded, "Least recently used result is evicted")
    }
}

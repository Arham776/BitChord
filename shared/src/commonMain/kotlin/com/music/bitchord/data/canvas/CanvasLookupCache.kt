package com.music.bitchord.data.canvas

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

/** Provider misses are temporary; identical requests share work, distinct songs do not share a lock. */
internal class CanvasLookupCache(
    private val scope: CoroutineScope,
    private val now: () -> Long = ::canvasNowMs,
    private val capacity: Int = 64,
    private val hitTtlMs: Long = 30 * 60 * 1000,
    private val missTtlMs: Long = 30 * 1000,
) {
    private data class Entry(val art: CanvasArtworkDto?, val expires: Long)
    private val lock = Mutex()
    private val slots = Semaphore(4)
    private val cache = LinkedHashMap<String, Entry>()
    private val inFlight = mutableMapOf<String, Deferred<CanvasArtworkDto?>>()

    suspend fun resolve(key: String, lookup: suspend () -> CanvasArtworkDto?): CanvasArtworkDto? {
        var saved: Entry? = null
        val work = lock.withLock {
            cache.remove(key)?.takeIf { now() < it.expires }?.let { entry ->
                cache[key] = entry
                saved = entry
                return@withLock null
            }
            inFlight[key] ?: scope.async(start = CoroutineStart.LAZY) {
                try {
                    val art = slots.withPermit { lookup() }
                    lock.withLock {
                        cache[key] = Entry(art, now() + if (art == null) missTtlMs else hitTtlMs)
                        while (cache.size > capacity) cache.entries.iterator().run { next(); remove() }
                    }
                    art
                } finally {
                    lock.withLock { inFlight.remove(key) }
                }
            }.also { inFlight[key] = it }
        }
        saved?.let { return it.art }
        return work!!.await()
    }
}

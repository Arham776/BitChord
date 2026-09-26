package com.music.bitchord.data.remote

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Embedded covers for remote tracks, extracted lazily and cached.
 *
 * Port of upstream `data/remote/RemoteArtworkStore.kt`, with one tier removed.
 *
 * A listing never touches audio bytes, so a track whose art lives inside the file
 * arrives with no thumbnail. The first surface that wants to draw it — a row, an album
 * header, the player — asks here instead, and only that one does. Concurrent asks for
 * one track share a single extraction, because a list scrolling past twenty rows of an
 * untagged share would otherwise fire twenty ranged reads at the same file.
 *
 * ## Why there is no disk tier
 *
 * Upstream has memory, then a directory of extracted pictures, then the ranged reads.
 * The disk tier exists for a reason that does not apply here: upstream has to hand Coil
 * a *URI*, because a Coil fetcher is the only thing that will draw an image, and a URI
 * has to name something on disk or on the network. This port hands the bytes to the
 * caller and the platform decodes them, so there is nothing that needs a file — and a
 * cache that has to be sized, swept and invalidated is a cache that will eventually
 * serve the cover of a track that has since been replaced on the share.
 *
 * What is kept is the part that earns its place: the memory tier, so a track drawn
 * twice in a session costs one ranged read rather than two, and a byte budget, so a
 * five-hundred-track library cannot grow the cache without bound.
 *
 * ## Every access is under the lock
 *
 * Including the reads, which is the uninteresting half of the design and the half that
 * matters here: [resolveArt] is called from whichever dispatcher a row happens to be
 * drawn on, and an `ArrayDeque` mutated from two of them is a crash rather than a
 * subtle wrong answer. An uncontended `Mutex` costs a compare-and-set.
 */
object RemoteArtworkStore {

    /** The most a picture may weigh to be cached at all. */
    private const val MAX_PICTURE_BYTES = 2L * 1024 * 1024

    /** The most the cache may hold in total before it starts forgetting. */
    private const val MAX_TOTAL_BYTES = 48L * 1024 * 1024

    private val mutex = Mutex()

    private val memory = HashMap<String, EmbeddedArt.Picture>()

    /** Insertion-ordered by recency: the first key is the one to be forgotten next. */
    private val order = ArrayDeque<String>()
    private var totalBytes = 0L

    private val inFlight = HashMap<String, CompletableDeferred<EmbeddedArt.Picture?>>()

    /**
     * The picture inside [fileUrl]'s file, or null when it has none.
     *
     * Never throws, and never fetches the whole file — only the few kilobytes at its
     * front that a tag lives in.
     *
     * @param authHeader the share's `Authorization` header, or null for an open share
     */
    suspend fun resolveArt(fileUrl: String, authHeader: String? = null): EmbeddedArt.Picture? {
        mutex.withLock { hitLocked(fileUrl) }?.let { return it }

        // Create-or-find, and *who* did it, decided in one critical section. Two rows
        // that ask in the same instant must not both start an extraction, and the only
        // way to guarantee that is for the flag and the map entry to be written
        // together — a caller that found a deferred is a waiter, by definition.
        val (waiting, mine) = mutex.withLock {
            val existing = inFlight[fileUrl]
            if (existing != null) {
                existing to false
            } else {
                CompletableDeferred<EmbeddedArt.Picture?>().also { inFlight[fileUrl] = it } to true
            }
        }
        if (!mine) return runCatching { waiting.await() }.getOrNull()

        var result: EmbeddedArt.Picture? = null
        try {
            result = RemoteArtReader.picture(fileUrl, authHeader)
        } catch (e: CancellationException) {
            // The asker went away — the row it was drawing is gone from the list. The
            // waiters are told "no picture" rather than left waiting on a deferred
            // nobody is left to complete.
            mutex.withLock { inFlight.remove(fileUrl) }
            waiting.complete(null)
            throw e
        } catch (_: Throwable) {
            result = null
        }
        // Stored before the waiters are released, so a caller arriving in between finds
        // it in memory rather than starting a second extraction.
        mutex.withLock {
            inFlight.remove(fileUrl)
            storeLocked(fileUrl, result)
        }
        waiting.complete(result)
        return result
    }

    /**
     * Forgets everything, for a share whose address just changed.
     *
     * Not for a changed *password*: the picture bytes do not depend on the credential,
     * only the ability to fetch them does, and a wrong password re-extracts to exactly
     * the same pictures. A changed address is a different share.
     */
    suspend fun clear() = mutex.withLock {
        memory.clear()
        order.clear()
        totalBytes = 0
    }

    /** The cached picture for [key], counting as a use. The lock is held. */
    private fun hitLocked(key: String): EmbeddedArt.Picture? {
        val picture = memory[key] ?: return null
        touchLocked(key)
        return picture
    }

    private fun touchLocked(key: String) {
        // Re-insert so the key moves to the young end. A `LinkedHashMap` in access
        // order would do this itself, and `java.util.LinkedHashMap` is JVM-only — so
        // the order is kept here and the map is the plain one.
        if (order.remove(key)) order.addLast(key)
    }

    /** The lock is held. */
    private fun storeLocked(key: String, picture: EmbeddedArt.Picture?) {
        if (picture == null || picture.bytes.size > MAX_PICTURE_BYTES) return
        if (key in memory) return
        memory[key] = picture
        order.addLast(key)
        totalBytes += picture.bytes.size
        while (totalBytes > MAX_TOTAL_BYTES && order.isNotEmpty()) {
            val oldest = order.removeFirst()
            memory.remove(oldest)?.let { totalBytes -= it.bytes.size }
        }
    }
}

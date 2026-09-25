package com.music.bitchord.data.sources.module

import com.music.bitchord.data.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.concurrent.Volatile
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Port of upstream `data/sources/module/SharedCalls.kt` — one in-flight-or-recent
 * answer per key, shared by everyone who asks for it.
 *
 * ## Why this exists
 *
 * A track simply passes through the resolve path several times over — the live
 * resolve, the second look under the music, the lossless pass after a lossy
 * swap, a re-resolve when the player reopens the source — and before this,
 * every one of those started from nothing. Measured upstream: one track, one
 * ninety-second window, one module, and the identical query searched twice and
 * the identical stream URL asked for twice. None of that is a bug in any one
 * caller.
 *
 * ## Two things are shared, and they are not the same thing
 *
 *  - **In flight**, always, whatever [ttl] says. Two callers asking the same
 *    question at the same moment is the ordinary case in this layer, because a
 *    search and a stream lookup overlap across tracks.
 *  - **Completed**, for [ttl]. Zero means in-flight only.
 *
 * ## Why the work is not started in the caller's scope
 *
 * Because this layer's callers are *designed* to give up:
 * [SourceResolver][com.music.bitchord.data.sources.SourceResolver] cancels every
 * source still running the moment one of them answers. Started in the caller's
 * scope, each of those cancellations tore down a request that had already
 * reached the server — so the server did the work, answered, and found nobody
 * listening. From the far end that is indistinguishable from a client hammering
 * it and hanging up, and it was a large part of what the module's operator was
 * seeing.
 *
 * ## What is not kept
 *
 * A failure. A source that was briefly unreachable should be asked again on the
 * next track rather than written off for the window. An *empty* answer is not a
 * failure: "this catalogue does not have that recording" is a real answer, and
 * re-asking for it is exactly the waste this exists to stop.
 */
internal class SharedCalls<T>(
    private val ttl: Duration,
    private val scope: CoroutineScope,
    /** Where a reuse is reported, so a log still shows one line per question asked. */
    private val log: (String) -> Unit = {},
) {

    /**
     * The work behind one key, and when it was started.
     *
     * Held as the running [Deferred] rather than as its result, which is what lets
     * a caller arriving mid-flight wait on it instead of starting a second copy.
     */
    private class Pending<T>(val work: Deferred<Result<T>>, val startedAt: TimeMark)

    private val entries = HashMap<String, Pending<T>>()

    /**
     * Held across the lookup *and* the insert. Two coroutines missing together
     * would otherwise each start their own call, which is the case this is most
     * needed for.
     */
    private val lock = Mutex()

    suspend fun get(
        key: String,
        describe: () -> String,
        produce: suspend () -> Result<T>,
    ): Result<T> {
        val entry = lock.withLock {
            val live = entries[key]?.takeIf {
                it.work.isActive || it.startedAt.elapsedNow() < ttl
            }
            if (live != null) {
                log(describe() + if (live.work.isActive) " — ALREADY RUNNING" else " — CACHE HIT")
                live
            } else {
                if (entries.size >= MAX_ENTRIES) prune()
                Pending(scope.async { produce() }, TimeSource.Monotonic.markNow()).also {
                    entries[key] = it
                }
            }
        }
        return entry.work.await().also { result ->
            // By identity, so a retry that has already replaced this entry is not
            // thrown away along with the failure it replaced. `HashMap` has no
            // two-argument `remove`, so the identity check is explicit — removing
            // blind would drop a *newer* entry that a retry had already installed
            // for this key, and with it a call that is still in flight.
            if (result.isFailure && entries[key] === entry) entries.remove(key)
        }
    }

    /** Everything held, dropped — the configuration it was all about is gone. */
    fun clear() = entries.clear()

    /**
     * Drops answers that have already completed, while preserving work still in
     * flight.
     *
     * An explicit refresh should ask the server again instead of accepting a
     * cached empty response, but it should not detach from a request already on
     * the wire and cause a duplicate beside it. The next caller therefore still
     * joins running work and starts fresh for everything else.
     */
    fun clearCompleted() {
        entries.entries.removeAll { !it.value.work.isActive }
    }

    /** For diagnostics: how many answers are being held. */
    internal fun size(): Int = entries.size

    /**
     * Drops the entries nearest expiry.
     *
     * Only reached when the map is full, which is bounded work — the capacity
     * check is a backstop against an unbounded key space (a search typed per
     * keystroke would otherwise be one entry each), not a routine cost.
     */
    private fun prune() {
        entries.entries.sortedBy { it.value.startedAt.elapsedNow() }
            .take(entries.size / 4)
            .forEach { entries.remove(it.key) }
        if (entries.size >= MAX_ENTRIES) entries.clear()
    }

    private companion object {
        /** Enough for a queue's worth of questions; past it, the oldest go. */
        const val MAX_ENTRIES = 128
    }
}

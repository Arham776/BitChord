@file:OptIn(ExperimentalAtomicApi::class)

package com.music.bitchord.data.listentogether

import kotlin.concurrent.Volatile
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.math.abs

/**
 * This device's offset from the party server's clock.
 *
 * Everything a party shares is on the server's timeline — a position, and the
 * server time it was true at — so a device that cannot translate that into its own
 * cannot be in sync, however fast its connection is. This is the translation.
 *
 * The method is NTP's, cut down to the part that matters over one WebSocket:
 *
 * ```
 * offset     = serverMs - (t0 + t1) / 2
 * roundTrip  = t1 - t0
 * ```
 *
 * and the error on that offset is at most half the round trip, because the only
 * thing assumed is that the two legs took the same time. Which is why the sample
 * with the *smallest* round trip wins rather than the newest or the average: on a
 * mobile network a single request delayed behind a radio wake-up is wrong by
 * hundreds of milliseconds, and averaging folds that error in instead of discarding
 * it. A short burst of pings on connect therefore converges faster than a long
 * series would.
 *
 * ## Why the caller supplies the local clock
 *
 * This is portable, so the local half of every sample is passed in rather than
 * read. That is not an abstraction for its own sake: the local timeline has to be
 * **monotonic and boot-relative**, and the only portable clock that is both is a
 * choice each platform makes differently. Reading the wall clock instead would put
 * every network time adjustment, every manual time change and every DST step
 * straight into the offset, moving this device's playhead relative to everyone
 * else's mid-track. On Apple the caller passes
 * `ProcessInfo.processInfo.systemUptime`; the note on [localNow] says why that one.
 */
class ServerClock {

    private data class Sample(val offsetMs: Long, val roundTripMs: Long, val takenAtMs: Long)

    /**
     * The window, held as one immutable value behind an atomic reference.
     *
     * Copy-on-write rather than a lock, for the same reason `StreamResolver`'s map
     * is: a sample arrives on a pong — a handful of times a session — while
     * [positionFor] is read on every tick of the player, so replacing the list per
     * write costs far less than the contention a lock would. And `synchronized` is
     * JVM-only, which the port discovers the hard way.
     */
    private val window = AtomicReference<List<Sample>>(emptyList())

    @Volatile
    var offsetMs: Long? = null
        private set

    @Volatile
    var roundTripMs: Long = 0
        private set

    /** True once at least one round trip has completed. */
    val synced: Boolean get() = offsetMs != null

    /**
     * Record one completed round trip.
     *
     * @param sentAtLocalMs the local monotonic reading stamped on the outgoing ping
     * @param serverMs the server's own reading, carried back on the pong
     * @param receivedAtLocalMs the local reading when the pong arrived
     */
    fun record(sentAtLocalMs: Long, serverMs: Long, receivedAtLocalMs: Long) {
        val roundTrip = (receivedAtLocalMs - sentAtLocalMs).coerceAtLeast(0)
        val midpoint = sentAtLocalMs + roundTrip / 2
        val fresh = Sample(serverMs - midpoint, roundTrip, receivedAtLocalMs)
        var chosen: Sample? = null
        while (true) {
            val current = window.load()
            val next = (current + fresh).takeLast(WINDOW)
            // Stale samples are dropped before choosing, or one lucky round trip
            // early in a session would pin the offset for the whole of it — and
            // clocks do drift, a phone by milliseconds per minute.
            val cutoff = receivedAtLocalMs - SAMPLE_TTL
            val usable = next.filter { it.takenAtMs >= cutoff }.ifEmpty { next }
            chosen = usable.minBy { it.roundTripMs }
            if (window.compareAndSet(current, next)) break
        }
        val best = chosen ?: fresh
        offsetMs = best.offsetMs
        roundTripMs = best.roundTripMs
    }

    /** The server's clock, read from here. Null until the first pong lands. */
    fun serverNowMs(localNowMs: Long): Long? = offsetMs?.let { localNowMs + it }

    /**
     * The server time at which a party position was true.
     *
     * This is the whole reason for the class: a position is shared with the server
     * time it was true *at*, and converting that to where this device ought to be
     * now is the only arithmetic the feature needs.
     *
     * Never negative and never in the past: a position slightly ahead of this
     * device's clock is held until it is reached rather than played early, because
     * playing early means the same bar of music is heard at two different moments,
     * which is the one thing a party is not.
     */
    fun positionFor(positionMs: Long, trueAtServerMs: Long, localNowMs: Long): Long {
        val now = serverNowMs(localNowMs) ?: return 0
        return (positionMs + (now - trueAtServerMs)).coerceAtLeast(0)
    }

    fun reset() {
        window.store(emptyList())
        offsetMs = null
        roundTripMs = 0
    }

    /** Visible for tests. */
    internal fun sampleCount(): Int = window.load().size

    /** Visible for tests. */
    internal fun sampleRoundTrips(): List<Long> = window.load().map { it.roundTripMs }

    companion object {
        /**
         * How many samples are kept, and how long one stays usable.
         *
         * Twelve is roughly a minute of pinging every five seconds — enough that
         * the minimum round trip is drawn from a dozen draws rather than two, and
         * few enough that a burst of connect pings converges immediately.
         */
        const val WINDOW = 12

        /**
         * How long a sample stays usable.
         *
         * Two minutes. Long enough to survive a tunnel, short enough that drift
         * over a long session is re-estimated rather than carried.
         */
        const val SAMPLE_TTL = 120_000L
    }
}

/**
 * How far two clocks can plausibly disagree before they are not the same clock.
 *
 * A shared tolerance rather than a per-call one, because the question is always
 * "is this device roughly in time with the party", and two devices answering it
 * with different numbers is how a party ends up silently out of sync while every
 * participant believes they are in it.
 */
const val PARTY_SYNC_TOLERANCE_MS = 750L

/**
 * Whether a position is close enough to the party's to be considered in sync.
 *
 * Compared against the *gap*, not the offset: two devices whose clocks are each
 * within tolerance of the server can still be a tolerance apart from each other,
 * so a device at the edge of tolerance must not claim to be in sync with one at
 * the other edge.
 */
fun isInSync(gapMs: Long): Boolean = abs(gapMs) <= PARTY_SYNC_TOLERANCE_MS

package com.music.bitchord.data.lyrics

import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi

/**
 * Which mirrors to try, in what order, and which to skip for now.
 *
 * ## Why this exists
 *
 * LyricsPlus is six volunteer mirrors, and one of them currently serves a
 * certificate chain iOS will not accept: the chain stops at an intermediate
 * where a root should be, so every request to it fails ATS with `-9802`. Racing
 * the mirrors means the source still works, so the failure is invisible except
 * as a wall of system log noise on *every track* — one wasted TLS handshake per
 * track, for a host that was never going to answer.
 *
 * The fix needs one thing the code did not have: the difference between "this
 * host could not be reached" and "this host answered and does not have this
 * track". See [LyricsAttempt]. Without that distinction a mirror with a broken
 * certificate is indistinguishable from an empty catalogue, and the only honest
 * thing to do with it is keep trying it forever.
 *
 * ## Why the backoff is a doubling one and not a permanent write-off
 *
 * These are volunteer mirrors on free hosting. A certificate gets fixed; a
 * deployment gets rolled back. Writing a host off for the rest of the session
 * means the source quietly loses a mirror it needed, and the failure only shows
 * up later as a track with no lyrics. Doubling caps at [MAX_BACKOFF_MS] and then
 * retries anyway: a host that is still down costs one timed-out request once
 * every few minutes, which is nothing next to a wall of log noise.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class MirrorHealth(
    private val now: () -> Long = { kotlin.time.TimeSource.Monotonic.markNow().let { _ -> clockMs() } },
) {
    private data class Host(val host: String, val failures: Int, val retryAfterMs: Long)

    private data class State(val hosts: List<Host> = emptyList(), val lastGood: String? = null)
    private val state = AtomicReference(State())

    // Playback prefetch and two download workers can query mirrors at once.
    // Publish immutable snapshots so a failure never mutates another request's list.
    private fun update(transform: (State) -> State): State {
        while (true) {
            val current = state.load()
            val next = transform(current)
            if (state.compareAndSet(current, next)) return next
        }
    }
    val lastGood: String? get() = state.load().lastGood
    val skippedCount: Int get() = state.load().hosts.count { it.retryAfterMs > 0L }

    /**
     * The hosts to try, best first, with the skipped ones left out.
     *
     * Always returns at least one host. A health table that talked itself into
     * an empty list would report "no lyrics" for a track that LyricsPlus has,
     * and the caller would have no way to tell that from a catalogue miss.
     */
    fun order(mirrors: List<String>): List<String> {
        val now = now()
        val snapshot = update { it.copy(hosts = it.hosts.filter { host -> host.host in mirrors }) }
        val hosts = snapshot.hosts
        val due = hosts.filter { it.retryAfterMs <= now }.map { it.host }.toSet()
        // Due hosts are retried, and hosts never seen before are always due: a
        // host that has never been asked cannot be written off.
        val eligible = mirrors.filter { it in due || hosts.none { h -> h.host == it } }
        val live = if (eligible.isEmpty()) mirrors else eligible
        return snapshot.lastGood?.let { good ->
            buildList {
                if (live.contains(good)) add(good)
                addAll(live.filterNot { it == good })
            }
        } ?: live
    }

    /** The host answered. Its penalty is cleared and it becomes the first try. */
    fun answered(host: String) {
        update { it.copy(hosts = it.hosts.filterNot { item -> item.host == host }, lastGood = host) }
    }

    /** The host answered but has nothing for this track. Not a fault of the host. */
    fun empty(host: String) {
        // Deliberately does not clear `lastGood`. A host that answered is a
        // working host, and the fact that this particular track was not in it
        // says nothing about which one to try first next time.
    }

    /**
     * The host could not be reached. Its penalty doubles, up to the cap.
     *
     * The first failure costs one skipped request, not a write-off: a single
     * blip should not remove a mirror from rotation, and the doubling is what
     * makes the *second* failure start to matter.
     */
    fun unreachable(host: String) {
        update { current ->
            val previous = current.hosts.firstOrNull { it.host == host }
            val failures = (previous?.failures ?: 0) + 1
            val delay = (BASE_BACKOFF_MS shl (failures - 1).coerceAtMost(6)).coerceAtMost(MAX_BACKOFF_MS)
            current.copy(
                hosts = current.hosts.filterNot { it.host == host } + Host(host, failures, now() + delay),
                lastGood = current.lastGood.takeUnless { it == host },
            )
        }
    }

    fun reset() { state.store(State()) }

    private companion object {
        const val BASE_BACKOFF_MS = 30_000L
        const val MAX_BACKOFF_MS = 15 * 60_000L

        /**
         * A monotonic reading in milliseconds.
         *
         * `TimeSource.Monotonic` is the right clock — a wall clock jumping back
         * would extend every penalty, and a penalty is measured in "how long has
         * this host been failing", which is elapsed time and not a date.
         */
        fun clockMs(): Long = kotlin.time.TimeSource.Monotonic.markNow().let {
            // `markNow().elapsedNow()` is always zero, so the reading is taken
            // against the process's own start instead: a monotonic duration
            // since launch, which is all a backoff needs.
            launchMark.elapsedNow().inWholeMilliseconds
        }

        val launchMark = kotlin.time.TimeSource.Monotonic.markNow()
    }
}

package com.music.bitchord.playback

import com.music.bitchord.data.model.Song
import kotlin.random.Random

/**
 * Port of upstream `playback/QueueShuffle.kt`, reshaped for an Apple-side
 * queue owner: upstream drives ExoPlayer's live queue with move operations;
 * here the queue is an immutable list the Swift controller applies. The
 * decision logic — picked track leads, rest at random, AutoPlay below the
 * user's own, pre-shuffle order remembered for restore — is upstream's.
 */
object QueueShuffle {

    /** Media ids in their pre-shuffle order. Empty while shuffle is off. */
    private var original: List<String> = emptyList()

    fun isShuffledStart(songs: List<Song>, startIndex: Int): List<Song> {
        original = songs.map { it.videoId }
        val rest = songs.filterIndexed { i, _ -> i != startIndex }.shuffled(Random.Default)
        return listOf(songs[startIndex]) + rest
    }

    /** The moves that take [current] into [target] from [from] onwards. */
    internal fun moves(
        current: List<String>,
        from: Int,
        target: List<String>,
    ): List<Pair<Int, Int>> {
        val ids = current.toMutableList()
        val out = mutableListOf<Pair<Int, Int>>()
        target.forEachIndexed { offset, id ->
            val to = from + offset
            if (ids.getOrNull(to) == id) return@forEachIndexed
            val at = (to + 1 until ids.size).firstOrNull { ids[it] == id }
                ?: return@forEachIndexed
            out += at to to
            ids.add(to, ids.removeAt(at))
        }
        return out
    }

    /** Applies the shuffle to the queue tail after the playing index. */
    fun shuffleQueue(queue: List<Song>, playingIndex: Int): List<Song> {
        if (queue.isEmpty() || playingIndex >= queue.size) return queue
        original = queue.map { it.videoId }
        val from = playingIndex + 1
        val autoplay = queue.drop(from)
            .mapIndexedNotNull { i, s -> if (s.fromAutoplay) i else null }
            .toSet()
        val ownShuffled = queue.drop(from)
            .filterIndexed { i, _ -> i !in autoplay }
            .shuffled(Random.Default)
        val mixShuffled = queue.drop(from)
            .filterIndexed { i, _ -> i in autoplay }
            .shuffled(Random.Default)
        return queue.take(from) + ownShuffled + mixShuffled
    }

    /** Puts the tracks still to come back into the order they were queued in. */
    fun restoreQueue(queue: List<Song>, playingIndex: Int): List<Song> {
        if (original.isEmpty()) return queue
        val from = playingIndex + 1
        val upcomingIds = queue.drop(from).map { it.videoId }.toMutableList()
        val restored = original.filter { upcomingIds.remove(it) }
            .mapNotNull { id -> queue.firstOrNull { it.videoId == id } } +
            upcomingIds.mapNotNull { id -> queue.firstOrNull { it.videoId == id } }
        original = emptyList()
        return queue.take(from) + restored
    }
}

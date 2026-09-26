package com.music.bitchord.data.playback

import com.music.bitchord.data.settings.PlatformSettings

/**
 * The tracks the listener has sent back to YouTube's own upload by hand, and
 * wants kept there. Upstream `OriginalVersion`, ported whole.
 *
 * "Revert to original" used to be a fact about one queue entry: the item was
 * replaced with a direct-YouTube one and that was the end of it. Play the same
 * song again tomorrow, or reach the end of the queue and come back round to it,
 * and the whole substitution and upgrade machinery started over from nothing and
 * put the listener right back on the copy they had just rejected. A revert is
 * not a preference about a moment; it is the listener saying this catalogue
 * match is wrong for this song, and the only useful lifetime for that is "until
 * they say otherwise".
 *
 * So it is written down, and [isPinned] is read wherever a stream is chosen —
 * not only while the queue entry that was reverted is still in memory, which is
 * the case a purely in-memory set would miss and the one most likely to be
 * noticed, because the queue is restored from disk.
 *
 * "Upgrade quality" is the way back out. Nothing else clears an entry: an
 * upgrade the app decided on by itself must not overturn one the listener asked
 * for, which is exactly what the automatic path would do given the chance.
 *
 * ## Why the set is stored as newline-separated text
 *
 * A YouTube video id is eleven characters from a fixed alphabet, so it cannot
 * contain a newline or a comma. That is the whole justification: newline is the
 * one separator that provably cannot occur inside a value, so no id can be
 * silently split into two pins by a round trip. A comma-separated list would
 * be equally short but would depend on a claim about the alphabet that this
 * file does not get to check; JSON would be the parser for a problem that does
 * not exist. Read through [decode] so the parsing rule is testable on its own.
 */
object OriginalVersion {

    private const val KEY = "original_version_pins"

    /**
     * Live set, so a resolution already in flight can see a pin that landed
     * while it was running. Read by [isPinned] on the path that decides what
     * plays, which is the whole point of writing it down.
     */
    private val pinned = mutableSetOf<String>()

    /** Reads the store once, at first use. */
    private val loaded: Boolean by lazy {
        pinned += decode(PlatformSettings.getString(KEY, ""))
        true
    }

    /** Which tracks are pinned, for a menu that has to offer the right row. */
    fun pinnedIds(): Set<String> {
        loaded
        return pinned.toSet()
    }

    /** Whether this track is being held on YouTube's own upload. */
    fun isPinned(videoId: String?): Boolean {
        if (videoId.isNullOrEmpty()) return false
        loaded
        return videoId in pinned
    }

    /** Holds [videoId] on YouTube's own upload from now on. */
    fun pin(videoId: String) {
        if (videoId.isEmpty()) return
        loaded
        if (pinned.add(videoId)) flush()
    }

    /**
     * Releases the hold, which is what "upgrade quality" is: the only thing
     * that clears a pin, because an automatic upgrade must never overturn a
     * decision the listener made.
     */
    fun unpin(videoId: String) {
        loaded
        if (pinned.remove(videoId)) flush()
    }

    /** Drops the pin for a track the app itself can no longer upgrade. */
    fun forget(videoId: String) = unpin(videoId)

    private fun flush() {
        PlatformSettings.putString(KEY, encode(pinned))
    }

    internal fun encode(ids: Set<String>): String = ids.sorted().joinToString("\n")

    /**
     * Reads the stored form back.
     *
     * Blank and whitespace-only lines are dropped rather than becoming pins for
     * tracks that do not exist: a hand-edited or truncated store must not be
     * able to invent a pin, and the cost of dropping one is that the listener
     * reverts once more, while the cost of keeping one is a track that silently
     * refuses to upgrade forever. Lines are trimmed, because a store written by
     * anything other than [encode] is not entitled to the assumption that
     * nothing was appended by hand.
     */
    internal fun decode(raw: String): Set<String> =
        raw.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()
}

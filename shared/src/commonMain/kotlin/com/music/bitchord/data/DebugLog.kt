package com.music.bitchord.data

import kotlin.concurrent.Volatile

/**
 * One place every diagnostic line goes through, so log output can be filtered
 * by tag and silenced wholesale.
 *
 * Upstream has two of these — [DebugLog] for ordinary call sites and
 * `TrackLog` for the playback/resolve path, where a Copy Log reader depends on
 * the output so it cannot be compiled out of a release build. The Apple port
 * has no log reader, so one object covers both jobs: the tag is the join key
 * that makes the output filterable, and [enabled] is the switch that makes it
 * silenceable.
 *
 * Deliberately not an `expect`/`actual` pair — there is no platform to
 * abstract. Kotlin/Native's `println` already reaches stderr on both iOS and
 * macOS, and on macOS `Console.app` picks it up under the process name.
 */
object DebugLog {

    const val TAG = "BitChord"

    /**
     * Off in a release build. Set from the host at startup; a default of true
     * keeps the resolve path legible during development without a wiring step
     * that is easy to forget.
     */
    @Volatile
    var enabled: Boolean = true

    fun d(message: String) {
        if (enabled) println("[$TAG] $message")
    }

    fun w(message: String) {
        if (enabled) println("[$TAG][warn] $message")
    }

    fun w(message: String, error: Throwable) {
        if (enabled) println("[$TAG][warn] $message: ${error::class.simpleName}: ${error.message}")
    }

    fun e(message: String, error: Throwable) {
        if (enabled) println("[$TAG][error] $message: ${error::class.simpleName}: ${error.message}")
    }
}

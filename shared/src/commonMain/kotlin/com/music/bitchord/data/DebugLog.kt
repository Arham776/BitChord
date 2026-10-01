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

    internal fun sanitize(message: String): String = message
        .replace(Regex("(?im)^.*(?:authorization\\s*[:=]|cookie\\s*[:=]|set-cookie\\s*[:=]).*$"), "<credential redacted>")
        .replace(Regex("(?i)(?:SAPISID|__Secure-[13]PAPISID|SID|HSID|sp_dc)=[^;\\s]+"), "<credential redacted>")
        .replace(Regex("https?://[^\\s\"<>]+")) { match ->
            runCatching {
                val url = io.ktor.http.Url(match.value)
                "${url.protocol.name}://${url.host}/<path redacted>"
            }.getOrDefault("<URL redacted>")
        }

    fun d(message: String) {
        if (enabled) println("[$TAG] ${sanitize(message)}")
    }

    fun w(message: String) {
        if (enabled) println("[$TAG][warn] ${sanitize(message)}")
    }

    fun w(message: String, error: Throwable) {
        if (enabled) println("[$TAG][warn] ${sanitize(message)}: ${error::class.simpleName}")
    }

    fun e(message: String, error: Throwable) {
        if (enabled) println("[$TAG][error] ${sanitize(message)}: ${error::class.simpleName}")
    }
}

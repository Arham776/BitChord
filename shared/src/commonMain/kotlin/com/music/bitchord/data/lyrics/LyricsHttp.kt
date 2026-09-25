package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json

private const val LYRICS_TIMEOUT_MS = 6_000L

internal const val LYRICS_AGENT = "BitChord (https://github.com/bitchord)"

internal val lyricsJson = Json { ignoreUnknownKeys = true; isLenient = true }

internal suspend fun lyricsGet(
    url: String,
    query: Map<String, String> = emptyMap(),
    /**
     * Replaces the agent for a host that shapes on it — see [Genius], which must
     * *not* claim to be a browser.
     */
    agent: String = LYRICS_AGENT,
    /** Extra headers, merged over the defaults. */
    headers: Map<String, String> = emptyMap(),
    /** Longer for a page than for a JSON document. */
    timeoutMillis: Long = LYRICS_TIMEOUT_MS,
): String? = runCatching {
    Http.getText(
        url,
        headers = mapOf(
            "User-Agent" to agent,
            "Accept" to "application/json",
        ) + headers,
        query = query,
        timeoutMillis = timeoutMillis,
    )
}.getOrNull()

internal suspend fun lyricsGetAuthorized(
    url: String,
    bearer: String,
    query: Map<String, String> = emptyMap(),
): String? = runCatching {
    Http.getText(
        url,
        headers = mapOf(
            "User-Agent" to LYRICS_AGENT,
            "Accept" to "application/json",
            "Authorization" to "Bearer $bearer",
            "Origin" to "https://music.apple.com",
            "Referer" to "https://music.apple.com/",
        ),
        query = query,
        timeoutMillis = LYRICS_TIMEOUT_MS,
    )
}.getOrNull()

/**
 * A plain bearer request, with no Apple headers.
 *
 * Separate from [lyricsGetAuthorized] because that one is an Apple Music call and
 * its `Origin` and `Referer` are part of what makes it work. Reusing it for a
 * third-party proxy would send Apple's origin to somebody else's host, which is
 * both wrong and a small leak of where the request came from.
 */
internal suspend fun lyricsGetBearer(
    url: String,
    bearer: String,
    query: Map<String, String> = emptyMap(),
): String? = runCatching {
    Http.getText(
        url,
        headers = mapOf(
            "User-Agent" to LYRICS_AGENT,
            "Accept" to "application/json",
            "Authorization" to "Bearer $bearer",
        ),
        query = query,
        timeoutMillis = LYRICS_TIMEOUT_MS,
    )
}.getOrNull()

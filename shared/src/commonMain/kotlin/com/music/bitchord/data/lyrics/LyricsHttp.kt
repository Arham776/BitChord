package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json

private const val LYRICS_TIMEOUT_MS = 6_000L

internal const val LYRICS_AGENT = "BitChord (https://github.com/bitchord)"

internal val lyricsJson = Json { ignoreUnknownKeys = true; isLenient = true }

/**
 * What a request to a lyrics backend actually produced.
 *
 * [lyricsGet] answers a single `null`, which folds "this track is not in this
 * catalogue" and "this host could not be reached" into the same value. That is
 * the right answer when all you want is lyrics, and the wrong one for a caller
 * that is trying to *learn* something about a host: a mirror with a broken
 * certificate looks exactly like an empty catalogue, so it keeps being retried
 * for every track and the system log fills with the same trust failure.
 *
 * So the two are separated, and only for the callers that need to tell them
 * apart. [Answered] and [Unreachable] are the whole distinction — there is no
 * third case, because a body that will not parse is the host's problem to have
 * and not a fact about the track.
 */
internal sealed interface LyricsAttempt {
    /** The host answered, and the body was read. It may still hold no lyrics. */
    data class Answered(val body: String) : LyricsAttempt

    /** The request never completed: DNS, TLS, a timeout, a refusal. */
    data object Unreachable : LyricsAttempt
}

/**
 * [lyricsGet], reporting which of the two happened.
 *
 * Shares the request with [lyricsGet] rather than repeating it, so the two
 * cannot drift on agent, headers or timeout — the kind of difference that shows
 * up as one mirror working and the other not, for no reason anyone can find.
 */
internal suspend fun lyricsAttempt(
    url: String,
    query: Map<String, String> = emptyMap(),
    agent: String = LYRICS_AGENT,
    headers: Map<String, String> = emptyMap(),
    timeoutMillis: Long = LYRICS_TIMEOUT_MS,
): LyricsAttempt = try {
    LyricsAttempt.Answered(
        Http.getText(
            url,
            headers = mapOf(
                "User-Agent" to agent,
                "Accept" to "application/json",
            ) + headers,
            query = query,
            timeoutMillis = timeoutMillis,
        ),
    )
} catch (e: Throwable) {
    // A cancellation is the caller's own decision, not the host's failure, and
    // recording it as one would write off a mirror because the app moved on.
    if (e is kotlinx.coroutines.CancellationException) throw e
    LyricsAttempt.Unreachable
}

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

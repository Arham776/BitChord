package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json

private const val LYRICS_TIMEOUT_MS = 6_000L

internal const val LYRICS_AGENT = "BitChord (https://github.com/bitchord)"

internal val lyricsJson = Json { ignoreUnknownKeys = true; isLenient = true }

internal suspend fun lyricsGet(
    url: String,
    query: Map<String, String> = emptyMap(),
): String? = runCatching {
    Http.getText(
        url,
        headers = mapOf("User-Agent" to LYRICS_AGENT, "Accept" to "application/json"),
        query = query,
        timeoutMillis = LYRICS_TIMEOUT_MS,
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

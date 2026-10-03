package com.music.bitchord.playback

import com.music.bitchord.data.model.Song
import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.innertube.Innertube
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * JSON wrapper so Swift can run upstream [QueueBuilder.extend] without
 * mapping Kotlin collection types across the FFI.
 */
object QueueBuilderBridge {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val songs = ListSerializer(Song.serializer())
    private val sessionIds = mutableSetOf<String>()
    private var generation = Innertube.sessionGeneration

    private fun checkSession() {
        val current = Innertube.sessionGeneration
        if (generation != current) {
            sessionIds.clear()
            generation = current
        }
    }

    fun rememberPlayed(videoId: String) {
        checkSession()
        if (videoId.isNotBlank()) sessionIds += videoId
    }

    fun clearSession() {
        sessionIds.clear()
    }

    fun extendJson(existingJson: String, candidatesJson: String, limit: Int): String {
        checkSession()
        val existing = runCatching { json.decodeFromString(songs, existingJson) }.getOrDefault(emptyList())
        val candidates = runCatching { json.decodeFromString(songs, candidatesJson) }.getOrDefault(emptyList())
        val skip = if (AppSettings.dontRepeatSuggestions.value) sessionIds else emptySet()
        val filtered = if (skip.isEmpty()) {
            candidates
        } else {
            candidates.filterNot { it.videoId in skip }
        }
        val extra = QueueBuilder.extend(existing, filtered, limit)
        // Only actually played songs enter sessionIds. Unplayed suggestions may
        // return in a fresh YouTube response after the previous tail is replaced.
        return json.encodeToString(songs, extra)
    }
}

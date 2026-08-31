package com.music.bitchord.playback

import com.music.bitchord.data.model.Song
import com.music.bitchord.data.settings.AppSettings
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

    fun rememberPlayed(videoId: String) {
        if (videoId.isNotBlank()) sessionIds += videoId
    }

    fun clearSession() {
        sessionIds.clear()
    }

    fun extendJson(existingJson: String, candidatesJson: String, limit: Int): String {
        val existing = runCatching { json.decodeFromString(songs, existingJson) }.getOrDefault(emptyList())
        val candidates = runCatching { json.decodeFromString(songs, candidatesJson) }.getOrDefault(emptyList())
        val skip = if (AppSettings.dontRepeatSuggestions.value) sessionIds else emptySet()
        val filtered = if (skip.isEmpty()) {
            candidates
        } else {
            candidates.filterNot { it.videoId in skip }
        }
        val extra = QueueBuilder.extend(existing, filtered, limit)
        extra.forEach { sessionIds += it.videoId }
        return json.encodeToString(songs, extra)
    }
}

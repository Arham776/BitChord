package com.music.bitchord.data

import com.music.bitchord.data.model.LikeStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Ratings changed during this app session, shared by the UI and playback.
 * Port of upstream `data/LikeState.kt`.
 */
object LikeState {
    private val _overrides = MutableStateFlow<Map<String, LikeStatus>>(emptyMap())
    val overrides: StateFlow<Map<String, LikeStatus>> = _overrides.asStateFlow()

    fun set(videoId: String, status: LikeStatus) {
        _overrides.value += (videoId to status)
    }

    fun get(videoId: String): LikeStatus? = _overrides.value[videoId]

    fun seedLiked(videoIds: Set<String>) {
        if (videoIds.isEmpty()) return
        val next = _overrides.value.toMutableMap()
        videoIds.forEach { id ->
            if (id !in next) next[id] = LikeStatus.LIKE
        }
        if (next != _overrides.value) _overrides.value = next
    }

    fun clear() {
        _overrides.value = emptyMap()
    }
}

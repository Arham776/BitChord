package com.music.bitchord.playback

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Port of upstream `playback/PlayerDeepLink.kt`: a one-shot "open the full
 * player" request. On Apple, the widget's deep link (spec §9) and the same
 * artwork-tap intent feed [consume]; the Now Playing view consumes the
 * pending flag exactly once via [handled].
 */
object PlayerDeepLink {

    private val _pending = MutableStateFlow(false)

    /** Whether a request is outstanding. Cleared by [handled]. */
    val pending: StateFlow<Boolean> = _pending.asStateFlow()

    /** The widget tap / deep link arrived. */
    fun consume(): Boolean {
        _pending.value = true
        return true
    }

    /** Called once the player has actually been opened — by whoever acted. */
    fun handled() {
        _pending.value = false
    }
}

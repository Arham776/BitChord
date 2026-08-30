package com.music.bitchord.data.settings


import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Port of upstream `data/settings/AppSettings.kt` — the settings the Apple app
 * consumes in v1, same keys, same semantics, `multiplatform-settings`
 * (NSUserDefaults) backing instead of DataStore per spec §1.3. Keys not listed
 * here await their feature milestones (scrobbling, Discord, lyrics sources…).
 *
 * Reads are StateFlows; writes go through the explicit setters, which persist
 * and publish atomically.
 */
object AppSettings {

    private val settings = PlatformSettings

    // ---- Playback ----------------------------------------------------------
    private val _crossfadeSeconds = MutableStateFlow(settings.getInt("crossfade_seconds", 0))
    /** Manual crossfade length in seconds; 0 = off (gapless still arms). */
    val crossfadeSeconds: StateFlow<Int> = _crossfadeSeconds.asStateFlow()
    fun setCrossfadeSeconds(value: Int) {
        _crossfadeSeconds.value = value.coerceIn(0, 12)
        settings.putInt("crossfade_seconds", _crossfadeSeconds.value)
    }

    private val _smartFadeEnabled = MutableStateFlow(settings.getBoolean("smart_fade_enabled", false))
    /** Automix (smart fade) toggle — plans land with the analyzer milestone. */
    val smartFadeEnabled: StateFlow<Boolean> = _smartFadeEnabled.asStateFlow()
    fun setSmartFadeEnabled(value: Boolean) {
        _smartFadeEnabled.value = value
        settings.putBoolean("smart_fade_enabled", value)
    }

    private val _spatialAudio = MutableStateFlow(settings.getBoolean("spatial_audio", false))
    /** Spatial widening (spec §3.3); disabled = sample-identical passthrough. */
    val spatialAudio: StateFlow<Boolean> = _spatialAudio.asStateFlow()
    fun setSpatialAudio(value: Boolean) {
        _spatialAudio.value = value
        settings.putBoolean("spatial_audio", value)
    }

    private val _autoplay = MutableStateFlow(settings.getBoolean("autoplay", true))
    val autoplay: StateFlow<Boolean> = _autoplay.asStateFlow()
    fun setAutoplay(value: Boolean) {
        _autoplay.value = value
        settings.putBoolean("autoplay", value)
    }

    // ---- Appearance --------------------------------------------------------
    private val _themeMode = MutableStateFlow(settings.getString("theme_mode", "dark"))
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()
    fun setThemeMode(value: String) {
        _themeMode.value = value
        settings.putString("theme_mode", value)
    }

    private val _reduceDynamicBlur = MutableStateFlow(settings.getBoolean("reduce_dynamic_blur", false))
    /** Upstream's glass swap: material chrome becomes a solid surface. */
    val reduceDynamicBlur: StateFlow<Boolean> = _reduceDynamicBlur.asStateFlow()
    fun setReduceDynamicBlur(value: Boolean) {
        _reduceDynamicBlur.value = value
        settings.putBoolean("reduce_dynamic_blur", value)
    }

    // ---- Local library -----------------------------------------------------
    private val _localLibraryPath = MutableStateFlow(settings.getString("local_library_path", ""))
    /** Security-scoped bookmark for the scanned local-music folder. */
    val localLibraryPath: StateFlow<String> = _localLibraryPath.asStateFlow()
    fun setLocalLibraryPath(value: String) {
        _localLibraryPath.value = value
        settings.putString("local_library_path", value)
    }
}

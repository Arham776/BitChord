package com.music.bitchord.data.settings

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class AudioQuality(val maxKbps: Int, val label: String) {
    LOW(64, "Low"),
    MEDIUM(128, "Medium"),
    HIGH(Int.MAX_VALUE, "High"),
    ;

    companion object {
        fun fromName(raw: String): AudioQuality =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: HIGH
    }
}

enum class DownloadQuality(val maxKbps: Int, val keepsLossless: Boolean, val label: String) {
    STANDARD(128, false, "Standard"),
    HIGH(Int.MAX_VALUE, false, "High"),
    LOSSLESS(Int.MAX_VALUE, true, "Lossless"),
    ;

    companion object {
        fun fromName(raw: String): DownloadQuality =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: LOSSLESS
    }
}

/**
 * Port of upstream `data/settings/AppSettings.kt`. Keys match Android so a
 * settings dump is readable across ports. Backed by [PlatformSettings].
 */
object AppSettings {

    private val settings = PlatformSettings

    // ---- Playback ----------------------------------------------------------
    private val _crossfadeSeconds = MutableStateFlow(settings.getInt("crossfade_seconds", 0))
    val crossfadeSeconds: StateFlow<Int> = _crossfadeSeconds.asStateFlow()
    fun setCrossfadeSeconds(value: Int) {
        _crossfadeSeconds.value = value.coerceIn(0, 12)
        settings.putInt("crossfade_seconds", _crossfadeSeconds.value)
    }

    private val _smartFadeEnabled = MutableStateFlow(settings.getBoolean("smart_fade_enabled", false))
    val smartFadeEnabled: StateFlow<Boolean> = _smartFadeEnabled.asStateFlow()
    fun setSmartFadeEnabled(value: Boolean) {
        _smartFadeEnabled.value = value
        settings.putBoolean("smart_fade_enabled", value)
    }

    private val _spatialAudio = MutableStateFlow(settings.getBoolean("spatial_audio", false))
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

    private val _skipSilence = MutableStateFlow(settings.getBoolean("skip_silence", false))
    val skipSilence: StateFlow<Boolean> = _skipSilence.asStateFlow()
    fun setSkipSilence(value: Boolean) {
        _skipSilence.value = value
        settings.putBoolean("skip_silence", value)
    }

    private val _playbackSpeed = MutableStateFlow(settings.getFloat("playback_speed", 1.0f))
    val playbackSpeed: StateFlow<Float> = _playbackSpeed.asStateFlow()
    fun setPlaybackSpeed(value: Float) {
        _playbackSpeed.value = value.coerceIn(0.5f, 2.0f)
        settings.putFloat("playback_speed", _playbackSpeed.value)
    }

    private val _audioQualityWifi = MutableStateFlow(
        AudioQuality.fromName(settings.getString("audio_quality_wifi", "HIGH")),
    )
    val audioQualityWifi: StateFlow<AudioQuality> = _audioQualityWifi.asStateFlow()
    fun setAudioQualityWifi(value: String) {
        val q = AudioQuality.fromName(value)
        _audioQualityWifi.value = q
        settings.putString("audio_quality_wifi", q.name)
    }

    private val _audioQualityCellular = MutableStateFlow(
        AudioQuality.fromName(settings.getString("audio_quality_cellular", "HIGH")),
    )
    val audioQualityCellular: StateFlow<AudioQuality> = _audioQualityCellular.asStateFlow()
    fun setAudioQualityCellular(value: String) {
        val q = AudioQuality.fromName(value)
        _audioQualityCellular.value = q
        settings.putString("audio_quality_cellular", q.name)
    }

    private val _downloadQuality = MutableStateFlow(
        DownloadQuality.fromName(settings.getString("download_quality", "LOSSLESS")),
    )
    val downloadQuality: StateFlow<DownloadQuality> = _downloadQuality.asStateFlow()
    fun setDownloadQuality(value: String) {
        val q = DownloadQuality.fromName(value)
        _downloadQuality.value = q
        settings.putString("download_quality", q.name)
    }

    private val _wifiOnlyDownloads = MutableStateFlow(settings.getBoolean("wifi_only_downloads", true))
    val wifiOnlyDownloads: StateFlow<Boolean> = _wifiOnlyDownloads.asStateFlow()
    fun setWifiOnlyDownloads(value: Boolean) {
        _wifiOnlyDownloads.value = value
        settings.putBoolean("wifi_only_downloads", value)
    }

    private val _showNerdStats = MutableStateFlow(settings.getBoolean("show_nerd_stats", false))
    val showNerdStats: StateFlow<Boolean> = _showNerdStats.asStateFlow()
    fun setShowNerdStats(value: Boolean) {
        _showNerdStats.value = value
        settings.putBoolean("show_nerd_stats", value)
    }

    private val _animatedCanvas = MutableStateFlow(settings.getBoolean("animated_canvas", true))
    val animatedCanvas: StateFlow<Boolean> = _animatedCanvas.asStateFlow()
    fun setAnimatedCanvas(value: Boolean) {
        _animatedCanvas.value = value
        settings.putBoolean("animated_canvas", value)
    }

    private val _canvasOverCellular = MutableStateFlow(settings.getBoolean("canvas_over_cellular", false))
    val canvasOverCellular: StateFlow<Boolean> = _canvasOverCellular.asStateFlow()
    fun setCanvasOverCellular(value: Boolean) {
        _canvasOverCellular.value = value
        settings.putBoolean("canvas_over_cellular", value)
    }

    // ---- Appearance --------------------------------------------------------
    private val _themeMode = MutableStateFlow(settings.getString("theme_mode", "dark"))
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()
    fun setThemeMode(value: String) {
        _themeMode.value = value
        settings.putString("theme_mode", value)
    }

    private val _reduceDynamicBlur = MutableStateFlow(settings.getBoolean("reduce_dynamic_blur", false))
    val reduceDynamicBlur: StateFlow<Boolean> = _reduceDynamicBlur.asStateFlow()
    fun setReduceDynamicBlur(value: Boolean) {
        _reduceDynamicBlur.value = value
        settings.putBoolean("reduce_dynamic_blur", value)
    }

    private val _reduceAnimation = MutableStateFlow(settings.getBoolean("reduce_animation", false))
    val reduceAnimation: StateFlow<Boolean> = _reduceAnimation.asStateFlow()
    fun setReduceAnimation(value: Boolean) {
        _reduceAnimation.value = value
        settings.putBoolean("reduce_animation", value)
    }

    private val _fullBleedArtwork = MutableStateFlow(settings.getBoolean("full_bleed_artwork", true))
    val fullBleedArtwork: StateFlow<Boolean> = _fullBleedArtwork.asStateFlow()
    fun setFullBleedArtwork(value: Boolean) {
        _fullBleedArtwork.value = value
        settings.putBoolean("full_bleed_artwork", value)
    }

    private val _syncedLyrics = MutableStateFlow(settings.getBoolean("synced_lyrics", true))
    val syncedLyrics: StateFlow<Boolean> = _syncedLyrics.asStateFlow()
    fun setSyncedLyrics(value: Boolean) {
        _syncedLyrics.value = value
        settings.putBoolean("synced_lyrics", value)
    }

    private val _convertVideoToAudio = MutableStateFlow(settings.getBoolean("convert_video_to_audio", true))
    val convertVideoToAudio: StateFlow<Boolean> = _convertVideoToAudio.asStateFlow()
    fun setConvertVideoToAudio(value: Boolean) {
        _convertVideoToAudio.value = value
        settings.putBoolean("convert_video_to_audio", value)
    }

    private val _swipeToPlayNext = MutableStateFlow(settings.getBoolean("swipe_to_play_next", false))
    val swipeToPlayNext: StateFlow<Boolean> = _swipeToPlayNext.asStateFlow()
    fun setSwipeToPlayNext(value: Boolean) {
        _swipeToPlayNext.value = value
        settings.putBoolean("swipe_to_play_next", value)
    }

    private val _dontRepeatSuggestions = MutableStateFlow(settings.getBoolean("dont_repeat_suggestions", false))
    val dontRepeatSuggestions: StateFlow<Boolean> = _dontRepeatSuggestions.asStateFlow()
    fun setDontRepeatSuggestions(value: Boolean) {
        _dontRepeatSuggestions.value = value
        settings.putBoolean("dont_repeat_suggestions", value)
    }

    private val _hideVolumeBar = MutableStateFlow(settings.getBoolean("hide_volume_bar", false))
    val hideVolumeBar: StateFlow<Boolean> = _hideVolumeBar.asStateFlow()
    fun setHideVolumeBar(value: Boolean) {
        _hideVolumeBar.value = value
        settings.putBoolean("hide_volume_bar", value)
    }

    private     val _lyricsSources = MutableStateFlow(
        settings.getString("lyrics_sources", "BETTER,PLUS,SIMP,LRCLIB"),
    )
    val lyricsSources: StateFlow<String> = _lyricsSources.asStateFlow()
    fun setLyricsSources(value: String) {
        _lyricsSources.value = value
        settings.putString("lyrics_sources", value)
    }

    private val _audioCacheLimitBytes = MutableStateFlow(
        settings.getLong("audio_cache_limit_bytes", DEFAULT_CACHE_LIMIT_BYTES)
            .coerceIn(DEFAULT_CACHE_LIMIT_BYTES, MAX_CACHE_LIMIT_BYTES),
    )
    val audioCacheLimitBytes: StateFlow<Long> = _audioCacheLimitBytes.asStateFlow()
    fun setAudioCacheLimitBytes(value: Long) {
        _audioCacheLimitBytes.value = value.coerceIn(DEFAULT_CACHE_LIMIT_BYTES, MAX_CACHE_LIMIT_BYTES)
        settings.putLong("audio_cache_limit_bytes", _audioCacheLimitBytes.value)
    }

    // ---- Local library -----------------------------------------------------
    private val _localLibraryPath = MutableStateFlow(settings.getString("local_library_path", ""))
    val localLibraryPath: StateFlow<String> = _localLibraryPath.asStateFlow()
    fun setLocalLibraryPath(value: String) {
        _localLibraryPath.value = value
        settings.putString("local_library_path", value)
    }

    // ---- Sources -----------------------------------------------------------
    private val _moduleIndexUrl = MutableStateFlow(settings.getString("module_index_url", ""))
    val moduleIndexUrl: StateFlow<String> = _moduleIndexUrl.asStateFlow()
    fun setModuleIndexUrl(value: String) {
        _moduleIndexUrl.value = value.trim()
        settings.putString("module_index_url", _moduleIndexUrl.value)
    }

    private val _customSourceUrl = MutableStateFlow(settings.getString("custom_source_url", ""))
    val customSourceUrl: StateFlow<String> = _customSourceUrl.asStateFlow()
    fun setCustomSourceUrl(value: String) {
        _customSourceUrl.value = value.trim()
        settings.putString("custom_source_url", _customSourceUrl.value)
    }

    private val _eqGains = MutableStateFlow(settings.getString("eq_gains", "0,0,0,0,0,0,0,0,0,0"))
    val eqGains: StateFlow<String> = _eqGains.asStateFlow()
    fun setEqGains(value: String) {
        _eqGains.value = value
        settings.putString("eq_gains", value)
    }

    // ---- Scrobbling --------------------------------------------------------
    private val _lastFmApiKey = MutableStateFlow(settings.getString("lastfm_api_key", ""))
    val lastFmApiKey: StateFlow<String> = _lastFmApiKey.asStateFlow()
    fun setLastFmApiKey(value: String) {
        _lastFmApiKey.value = value.trim()
        settings.putString("lastfm_api_key", _lastFmApiKey.value)
    }

    private val _lastFmSecret = MutableStateFlow(settings.getString("lastfm_secret", ""))
    val lastFmSecret: StateFlow<String> = _lastFmSecret.asStateFlow()
    fun setLastFmSecret(value: String) {
        _lastFmSecret.value = value.trim()
        settings.putString("lastfm_secret", _lastFmSecret.value)
    }

    private val _lastFmSession = MutableStateFlow(settings.getString("lastfm_session", ""))
    val lastFmSession: StateFlow<String> = _lastFmSession.asStateFlow()
    fun setLastFmSession(value: String) {
        _lastFmSession.value = value.trim()
        settings.putString("lastfm_session", _lastFmSession.value)
    }

    private val _lastFmUsername = MutableStateFlow(settings.getString("lastfm_username", ""))
    val lastFmUsername: StateFlow<String> = _lastFmUsername.asStateFlow()
    fun setLastFmUsername(value: String) {
        _lastFmUsername.value = value.trim()
        settings.putString("lastfm_username", _lastFmUsername.value)
    }

    private val _lastFmEnabled = MutableStateFlow(settings.getBoolean("lastfm_enabled", false))
    val lastFmEnabled: StateFlow<Boolean> = _lastFmEnabled.asStateFlow()
    fun setLastFmEnabled(value: Boolean) {
        _lastFmEnabled.value = value
        settings.putBoolean("lastfm_enabled", value)
    }

    private val _lastFmScrobble = MutableStateFlow(settings.getBoolean("lastfm_scrobble", true))
    val lastFmScrobble: StateFlow<Boolean> = _lastFmScrobble.asStateFlow()
    fun setLastFmScrobble(value: Boolean) {
        _lastFmScrobble.value = value
        settings.putBoolean("lastfm_scrobble", value)
    }

    private val _lastFmNowPlaying = MutableStateFlow(settings.getBoolean("lastfm_nowplaying", true))
    val lastFmNowPlaying: StateFlow<Boolean> = _lastFmNowPlaying.asStateFlow()
    fun setLastFmNowPlaying(value: Boolean) {
        _lastFmNowPlaying.value = value
        settings.putBoolean("lastfm_nowplaying", value)
    }

    private val _listenBrainzToken = MutableStateFlow(settings.getString("listenbrainz_token", ""))
    val listenBrainzToken: StateFlow<String> = _listenBrainzToken.asStateFlow()
    fun setListenBrainzToken(value: String) {
        _listenBrainzToken.value = value.trim()
        settings.putString("listenbrainz_token", _listenBrainzToken.value)
    }

    private val _listenBrainzEnabled = MutableStateFlow(settings.getBoolean("listenbrainz_enabled", false))
    val listenBrainzEnabled: StateFlow<Boolean> = _listenBrainzEnabled.asStateFlow()
    fun setListenBrainzEnabled(value: Boolean) {
        _listenBrainzEnabled.value = value
        settings.putBoolean("listenbrainz_enabled", value)
    }

    // ---- Discord -----------------------------------------------------------
    private val _discordToken = MutableStateFlow(settings.getString("discord_token", ""))
    val discordToken: StateFlow<String> = _discordToken.asStateFlow()
    fun setDiscordToken(value: String) {
        _discordToken.value = value.trim()
        settings.putString("discord_token", _discordToken.value)
    }

    private val _discordUsername = MutableStateFlow(settings.getString("discord_username", ""))
    val discordUsername: StateFlow<String> = _discordUsername.asStateFlow()
    fun setDiscordUsername(value: String) {
        _discordUsername.value = value.trim()
        settings.putString("discord_username", _discordUsername.value)
    }

    private val _discordRpcEnabled = MutableStateFlow(settings.getBoolean("discord_rpc_enabled", true))
    val discordRpcEnabled: StateFlow<Boolean> = _discordRpcEnabled.asStateFlow()
    fun setDiscordRpcEnabled(value: Boolean) {
        _discordRpcEnabled.value = value
        settings.putBoolean("discord_rpc_enabled", value)
    }

    private val _discordStatus = MutableStateFlow(settings.getString("discord_status", "online"))
    val discordStatus: StateFlow<String> = _discordStatus.asStateFlow()
    fun setDiscordStatus(value: String) {
        _discordStatus.value = value
        settings.putString("discord_status", value)
    }

    private val _discordActivityType = MutableStateFlow(settings.getString("discord_activity_type", "listening"))
    val discordActivityType: StateFlow<String> = _discordActivityType.asStateFlow()
    fun setDiscordActivityType(value: String) {
        _discordActivityType.value = value
        settings.putString("discord_activity_type", value)
    }

    private val _discordActivityName = MutableStateFlow(settings.getString("discord_activity_name", ""))
    val discordActivityName: StateFlow<String> = _discordActivityName.asStateFlow()
    fun setDiscordActivityName(value: String) {
        _discordActivityName.value = value
        settings.putString("discord_activity_name", value)
    }

    private val _discordSwapTitle = MutableStateFlow(settings.getBoolean("discord_swap_title", false))
    val discordSwapTitle: StateFlow<Boolean> = _discordSwapTitle.asStateFlow()
    fun setDiscordSwapTitle(value: Boolean) {
        _discordSwapTitle.value = value
        settings.putBoolean("discord_swap_title", value)
    }

    private val _scrobbleMinDuration = MutableStateFlow(settings.getInt("scrobble_min_duration", 30))
    val scrobbleMinDuration: StateFlow<Int> = _scrobbleMinDuration.asStateFlow()
    fun setScrobbleMinDuration(value: Int) {
        _scrobbleMinDuration.value = value.coerceIn(10, 120)
        settings.putInt("scrobble_min_duration", _scrobbleMinDuration.value)
    }

    private val _scrobbleDelayPercent = MutableStateFlow(settings.getFloat("scrobble_delay_percent", 0.5f))
    val scrobbleDelayPercent: StateFlow<Float> = _scrobbleDelayPercent.asStateFlow()
    fun setScrobbleDelayPercent(value: Float) {
        _scrobbleDelayPercent.value = value.coerceIn(0.25f, 0.9f)
        settings.putFloat("scrobble_delay_percent", _scrobbleDelayPercent.value)
    }

    private val _scrobbleDelaySeconds = MutableStateFlow(settings.getInt("scrobble_delay_seconds", 180))
    val scrobbleDelaySeconds: StateFlow<Int> = _scrobbleDelaySeconds.asStateFlow()
    fun setScrobbleDelaySeconds(value: Int) {
        _scrobbleDelaySeconds.value = value.coerceIn(30, 480)
        settings.putInt("scrobble_delay_seconds", _scrobbleDelaySeconds.value)
    }

    private val _pinnedPlaylists = MutableStateFlow(settings.getString("pinned_playlists", ""))
    val pinnedPlaylists: StateFlow<String> = _pinnedPlaylists.asStateFlow()
    fun setPinnedPlaylists(value: String) {
        _pinnedPlaylists.value = value
        settings.putString("pinned_playlists", value)
    }

    fun togglePinnedPlaylist(browseId: String) {
        val ids = _pinnedPlaylists.value.split(',').map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
        if (browseId in ids) ids.remove(browseId) else {
            if (ids.size >= 5) ids.removeAt(ids.lastIndex)
            ids.add(0, browseId)
        }
        setPinnedPlaylists(ids.joinToString(","))
    }

    private val _spotifySpdc = MutableStateFlow(settings.getString("spotify_spdc_token", ""))
    val spotifySpdc: StateFlow<String> = _spotifySpdc.asStateFlow()
    fun setSpotifySpdc(value: String) {
        _spotifySpdc.value = value.trim()
        settings.putString("spotify_spdc_token", _spotifySpdc.value)
    }

    private val _jiosaavnEnabled = MutableStateFlow(settings.getBoolean("jiosaavn_enabled", true))
    val jiosaavnEnabled: StateFlow<Boolean> = _jiosaavnEnabled.asStateFlow()
    fun setJiosaavnEnabled(value: Boolean) {
        _jiosaavnEnabled.value = value
        settings.putBoolean("jiosaavn_enabled", value)
    }

    private val _stopWhenBackgrounded = MutableStateFlow(settings.getBoolean("stop_when_backgrounded", false))
    val stopWhenBackgrounded: StateFlow<Boolean> = _stopWhenBackgrounded.asStateFlow()
    fun setStopWhenBackgrounded(value: Boolean) {
        _stopWhenBackgrounded.value = value
        settings.putBoolean("stop_when_backgrounded", value)
    }

    private val _prioritizeSyllableSync = MutableStateFlow(settings.getBoolean("prioritize_syllable_sync", true))
    val prioritizeSyllableSync: StateFlow<Boolean> = _prioritizeSyllableSync.asStateFlow()
    fun setPrioritizeSyllableSync(value: Boolean) {
        _prioritizeSyllableSync.value = value
        settings.putBoolean("prioritize_syllable_sync", value)
    }

    private val _replayGenres = MutableStateFlow(settings.getBoolean("replay_genres", true))
    val replayGenres: StateFlow<Boolean> = _replayGenres.asStateFlow()
    fun setReplayGenres(value: Boolean) {
        _replayGenres.value = value
        settings.putBoolean("replay_genres", value)
    }

    /** Keys that must never leave the device in a backup. */
    private val SECRET_KEYS = setOf(
        "discord_token", "lastfm_session", "lastfm_secret", "lastfm_api_key",
        "listenbrainz_token", "spotify_spdc_token",
    )

    fun exportPrefsJson(): String {
        val keys = listOf(
            "crossfade_seconds", "smart_fade_enabled", "spatial_audio", "autoplay",
            "skip_silence", "playback_speed", "audio_quality_wifi", "audio_quality_cellular",
            "download_quality", "wifi_only_downloads", "show_nerd_stats", "animated_canvas",
            "canvas_over_cellular", "theme_mode", "reduce_dynamic_blur", "reduce_animation",
            "full_bleed_artwork", "synced_lyrics", "convert_video_to_audio", "swipe_to_play_next",
            "dont_repeat_suggestions", "hide_volume_bar", "lyrics_sources", "audio_cache_limit_bytes",
            "eq_gains", "pinned_playlists", "jiosaavn_enabled", "stop_when_backgrounded",
            "prioritize_syllable_sync", "replay_genres", "scrobble_min_duration", "scrobble_delay_percent",
            "scrobble_delay_seconds", "discord_rpc_enabled", "discord_status",
            "discord_activity_type", "discord_activity_name", "discord_swap_title",
        )
        val parts = keys.map { key ->
            val value = when (key) {
                "crossfade_seconds", "scrobble_min_duration", "scrobble_delay_seconds" ->
                    settings.getInt(key, 0).toString()
                "audio_cache_limit_bytes" -> settings.getLong(key, DEFAULT_CACHE_LIMIT_BYTES).toString()
                "scrobble_delay_percent", "playback_speed" -> settings.getFloat(key, 0f).toString()
                "smart_fade_enabled", "spatial_audio", "autoplay", "skip_silence",
                "wifi_only_downloads", "show_nerd_stats", "animated_canvas", "canvas_over_cellular",
                "reduce_dynamic_blur", "reduce_animation", "full_bleed_artwork", "synced_lyrics",
                "convert_video_to_audio", "swipe_to_play_next", "dont_repeat_suggestions",
                "hide_volume_bar", "jiosaavn_enabled", "stop_when_backgrounded",
                "prioritize_syllable_sync", "replay_genres", "discord_rpc_enabled", "discord_swap_title",
                -> settings.getBoolean(key, false).toString()
                else -> settings.getString(key, "")
            }
            "\"$key\":${jsonString(value)}"
        }
        return "{${parts.joinToString(",")}}"
    }

    fun importPrefsJson(raw: String) {
        val obj = raw.trim().removePrefix("{").removeSuffix("}")
        obj.split("\",\"").forEach { chunk ->
            val cleaned = chunk.trim().removePrefix("\"").removeSuffix("\"")
            val idx = cleaned.indexOf("\":")
            if (idx <= 0) return@forEach
            val key = cleaned.substring(0, idx).replace("\"", "")
            if (key in SECRET_KEYS) return@forEach
            var value = cleaned.substring(idx + 2).trim()
            if (value.startsWith("\"")) value = value.removeSurrounding("\"")
            when (key) {
                "crossfade_seconds" -> setCrossfadeSeconds(value.toIntOrNull() ?: 0)
                "smart_fade_enabled" -> setSmartFadeEnabled(value.toBoolean())
                "spatial_audio" -> setSpatialAudio(value.toBoolean())
                "autoplay" -> setAutoplay(value.toBoolean())
                "skip_silence" -> setSkipSilence(value.toBoolean())
                "playback_speed" -> setPlaybackSpeed(value.toFloatOrNull() ?: 1f)
                "audio_quality_wifi" -> setAudioQualityWifi(value)
                "audio_quality_cellular" -> setAudioQualityCellular(value)
                "download_quality" -> setDownloadQuality(value)
                "wifi_only_downloads" -> setWifiOnlyDownloads(value.toBoolean())
                "show_nerd_stats" -> setShowNerdStats(value.toBoolean())
                "animated_canvas" -> setAnimatedCanvas(value.toBoolean())
                "canvas_over_cellular" -> setCanvasOverCellular(value.toBoolean())
                "theme_mode" -> setThemeMode(value)
                "reduce_dynamic_blur" -> setReduceDynamicBlur(value.toBoolean())
                "reduce_animation" -> setReduceAnimation(value.toBoolean())
                "full_bleed_artwork" -> setFullBleedArtwork(value.toBoolean())
                "synced_lyrics" -> setSyncedLyrics(value.toBoolean())
                "convert_video_to_audio" -> setConvertVideoToAudio(value.toBoolean())
                "swipe_to_play_next" -> setSwipeToPlayNext(value.toBoolean())
                "dont_repeat_suggestions" -> setDontRepeatSuggestions(value.toBoolean())
                "hide_volume_bar" -> setHideVolumeBar(value.toBoolean())
                "lyrics_sources" -> setLyricsSources(value)
                "audio_cache_limit_bytes" -> setAudioCacheLimitBytes(value.toLongOrNull() ?: DEFAULT_CACHE_LIMIT_BYTES)
                "eq_gains" -> setEqGains(value)
                "pinned_playlists" -> setPinnedPlaylists(value)
                "jiosaavn_enabled" -> setJiosaavnEnabled(value.toBoolean())
                "stop_when_backgrounded" -> setStopWhenBackgrounded(value.toBoolean())
                "prioritize_syllable_sync" -> setPrioritizeSyllableSync(value.toBoolean())
                "replay_genres" -> setReplayGenres(value.toBoolean())
                "scrobble_min_duration" -> setScrobbleMinDuration(value.toIntOrNull() ?: 30)
                "scrobble_delay_percent" -> setScrobbleDelayPercent(value.toFloatOrNull() ?: 0.5f)
                "scrobble_delay_seconds" -> setScrobbleDelaySeconds(value.toIntOrNull() ?: 180)
                "discord_rpc_enabled" -> setDiscordRpcEnabled(value.toBoolean())
                "discord_status" -> setDiscordStatus(value)
                "discord_activity_type" -> setDiscordActivityType(value)
                "discord_activity_name" -> setDiscordActivityName(value)
                "discord_swap_title" -> setDiscordSwapTitle(value.toBoolean())
            }
        }
    }

    private fun jsonString(s: String): String =
        "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    fun effectiveAudioQuality(metered: Boolean): AudioQuality =
        if (metered) audioQualityCellular.value else audioQualityWifi.value

    const val DEFAULT_CACHE_LIMIT_BYTES = 512L * 1024 * 1024
    const val MAX_CACHE_LIMIT_BYTES = 10L * 1024 * 1024 * 1024
}

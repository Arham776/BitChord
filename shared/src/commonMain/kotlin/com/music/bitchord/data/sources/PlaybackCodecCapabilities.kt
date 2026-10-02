package com.music.bitchord.data.sources

import com.music.bitchord.data.settings.AppSettings
import kotlin.concurrent.Volatile

/** Host decoder capabilities; native stereo decoding remains the default. */
object PlaybackCodecCapabilities {
    @Volatile private var appleDolbyAvailable = false
    fun setAppleDolbyAvailable(value: Boolean) { appleDolbyAvailable = value }
    fun canRenderDolby(codec: String?, headers: Map<String, String>): Boolean =
        appleDolbyAvailable && AppSettings.dolbyAtmos.value && headers.isEmpty() &&
            codec?.lowercase() in setOf("ac3", "ac-3", "eac3", "e-ac-3", "ec-3", "ec3", "eac3-joc", "ec3-joc", "dolby-atmos")
}

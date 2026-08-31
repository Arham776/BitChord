package com.music.bitchord.data.download

import com.music.bitchord.data.innertube.PlayerBridge
import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.settings.DownloadQuality
import com.music.bitchord.data.sources.SourceBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.coroutines.resume

object DownloadBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { encodeDefaults = true }

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, title: String, artist: String, callback: ResolveCallback) {
        scope.launch {
            val quality = AppSettings.downloadQuality.value
            val tier = if (quality.keepsLossless) "LOSSLESS" else if (quality == DownloadQuality.STANDARD) "LOW" else "HIGH"
            val custom = suspendCancellableCoroutine { cont ->
                SourceBridge.resolveCustom(title, artist, tier) { payload, _ ->
                    cont.resume(payload)
                }
            }
            if (custom != null) {
                callback.onResult(custom, null)
                return@launch
            }
            val maxKbps = if (quality.maxKbps == Int.MAX_VALUE) Int.MAX_VALUE else quality.maxKbps
            PlayerBridge.resolve(videoId, maxKbps) { payload, message ->
                callback.onResult(payload, message)
            }
        }
    }

    @Serializable
    data class PersistHint(val title: String, val artist: String, val album: String)
}

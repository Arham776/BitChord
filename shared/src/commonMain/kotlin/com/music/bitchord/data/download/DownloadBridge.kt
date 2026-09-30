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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlin.coroutines.resume

object DownloadBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { encodeDefaults = true }

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, title: String, artist: String, callback: ResolveCallback) {
        resolveAtQuality(videoId, title, artist, AppSettings.downloadQuality.value.name, callback)
    }

    fun resolveAtQuality(videoId: String, title: String, artist: String, qualityName: String, callback: ResolveCallback) {
        scope.launch {
            val quality = DownloadQuality.fromName(qualityName)
            val tier = if (quality.keepsLossless) "LOSSLESS" else if (quality == DownloadQuality.STANDARD) "LOW" else "HIGH"
            val custom = suspendCancellableCoroutine { cont ->
                SourceBridge.resolveCustom(title, artist, tier) { payload, _ ->
                    cont.resume(payload)
                }
            }
            if (custom != null) {
                val fields = json.parseToJsonElement(custom).jsonObject.toMutableMap()
                fields["provider"] = JsonPrimitive("custom:" + AppSettings.customSourceUrl.value.substringBefore('?').substringAfter("://").substringAfter('@').trimEnd('/'))
                fields["quality"] = JsonPrimitive(quality.name)
                callback.onResult(JsonObject(fields).toString(), null)
                return@launch
            }
            val maxKbps = if (quality.maxKbps == Int.MAX_VALUE) Int.MAX_VALUE else quality.maxKbps
            PlayerBridge.resolve(videoId, maxKbps) { payload, message ->
                if (payload == null) callback.onResult(null, message)
                else {
                    val fields = json.parseToJsonElement(payload).jsonObject.toMutableMap()
                    fields["provider"] = JsonPrimitive("youtube")
                    fields["recordingIdentity"] = JsonPrimitive(videoId)
                    fields["youtubeVideoId"] = JsonPrimitive(videoId)
                    fields["quality"] = JsonPrimitive(quality.name)
                    callback.onResult(JsonObject(fields).toString(), message)
                }
            }
        }
    }

    @Serializable
    data class PersistHint(val title: String, val artist: String, val album: String)
}

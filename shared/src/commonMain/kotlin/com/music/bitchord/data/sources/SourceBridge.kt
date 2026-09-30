package com.music.bitchord.data.sources

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Pluggable sources: a JSON HTTP endpoint and/or a Spine module index.
 *
 * Custom source contract:
 *   GET {base}/health
 *   GET {base}/stream?title=&artist=&quality=LOSSLESS|HIGH|LOW
 *     → { "streamUrl": "...", "codec": "flac", "kbps": 1411, "bitDepth": 16, "sampleRate": 44100 }
 *
 * Module index: upstream Spine JSON; JS execution happens in Swift.
 */
object SourceBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun interface HealthCallback {
        fun onResult(ok: Boolean, detail: String)
    }

    fun interface StreamCallback {
        fun onResult(json: String?, message: String?)
    }

    fun interface IndexCallback {
        fun onResult(json: String?, message: String?)
    }

    fun health(url: String, callback: HealthCallback) {
        scope.launch {
            val target = url.trim().trimEnd('/')
            if (target.isEmpty()) {
                callback.onResult(false, "No URL")
                return@launch
            }
            val body = runCatching { Http.getText("$target/health", timeoutMillis = 8_000) }.getOrNull()
            if (body != null) {
                callback.onResult(true, body.take(120).ifBlank { "Ok" })
            } else {
                val index = runCatching { Http.getText(target, timeoutMillis = 8_000) }.getOrNull()
                if (index != null && (index.contains("\"download\"") || index.contains("category:"))) {
                    callback.onResult(true, "Module index reachable")
                } else {
                    callback.onResult(false, "Unreachable")
                }
            }
        }
    }

    fun resolveCustom(
        title: String,
        artist: String,
        quality: String,
        callback: StreamCallback,
    ) {
        scope.launch {
            val base = AppSettings.customSourceUrl.value.trim().trimEnd('/')
            if (base.isEmpty()) {
                callback.onResult(null, "No custom source")
                return@launch
            }
            val body = runCatching {
                Http.getText(
                    "$base/stream",
                    query = mapOf("title" to title, "artist" to artist, "quality" to quality),
                    timeoutMillis = 20_000,
                )
            }.getOrNull()
            if (body.isNullOrBlank()) {
                callback.onResult(null, "Custom source returned nothing")
                return@launch
            }
            val obj = json.parseToJsonElement(body) as? JsonObject
            val url = obj?.get("streamUrl")?.jsonPrimitive?.contentOrNull
                ?: obj?.get("url")?.jsonPrimitive?.contentOrNull
            if (obj == null || url.isNullOrBlank()) {
                callback.onResult(null, "No streamUrl")
                return@launch
            }
            val payload = StreamHit(
                url = url,
                codec = obj["codec"]?.jsonPrimitive?.contentOrNull ?: guessCodec(url),
                kbps = obj["kbps"]?.jsonPrimitive?.intOrNull ?: 0,
                bitDepth = obj["bitDepth"]?.jsonPrimitive?.intOrNull ?: 0,
                sampleRate = obj["sampleRate"]?.jsonPrimitive?.intOrNull ?: 0,
                lossless = (obj["codec"]?.jsonPrimitive?.contentOrNull ?: guessCodec(url)).lowercase() in listOf("flac", "alac", "wav", "pcm"),
                recordingIdentity = obj["recordingIdentity"]?.jsonPrimitive?.contentOrNull ?: obj["id"]?.jsonPrimitive?.contentOrNull,
            )
            callback.onResult(json.encodeToString(StreamHit.serializer(), payload), null)
        }
    }

    fun fetchIndex(url: String, callback: IndexCallback) {
        scope.launch {
            val body = runCatching { Http.getText(url.trim(), timeoutMillis = 15_000) }.getOrNull()
            if (body == null) {
                callback.onResult(null, "Index unreachable")
                return@launch
            }
            val modules = parseIndex(body)
            callback.onResult(json.encodeToString(IndexListing.serializer(), IndexListing(modules)), null)
        }
    }

    fun downloadScript(url: String, callback: StreamCallback) {
        scope.launch {
            val body = runCatching { Http.getText(url, timeoutMillis = 20_000) }.getOrNull()
            callback.onResult(body, if (body == null) "Download failed" else null)
        }
    }

    private fun parseIndex(body: String): List<ModuleCard> {
        val root = json.parseToJsonElement(body)
        val bags = mutableListOf<JsonArray>()
        when (root) {
            is JsonArray -> bags += root
            is JsonObject -> {
                root.values.filterIsInstance<JsonArray>().forEach { bags += it }
                root.values.filterIsInstance<JsonObject>().forEach { nested ->
                    nested.values.filterIsInstance<JsonArray>().forEach { bags += it }
                }
            }
            else -> Unit
        }
        return bags.flatMap { arr ->
            arr.mapNotNull { el ->
                val o = el as? JsonObject ?: return@mapNotNull null
                val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                val name = o["name"]?.jsonPrimitive?.contentOrNull ?: id
                val download = o["download"]?.jsonPrimitive?.contentOrNull.orEmpty()
                val tags = (o["tags"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty() +
                    (o["labels"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
                ModuleCard(
                    id = id,
                    name = name,
                    author = o["author"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    version = o["version"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    download = download,
                    lossless = tags.any { it.contains("LOSSLESS", true) || it.contains("FLAC", true) || it.contains("HI-RES", true) },
                )
            }
        }.distinctBy { it.id }
    }

    private fun guessCodec(url: String): String {
        val ext = url.substringBefore('?').substringAfterLast('.').lowercase()
        return when (ext) {
            "flac" -> "FLAC"
            "alac" -> "ALAC"
            "mp3" -> "MP3"
            "m4a", "aac", "mp4" -> "AAC"
            else -> ext.uppercase().ifBlank { "unknown" }
        }
    }

    @Serializable
    data class StreamHit(
        val url: String,
        val codec: String,
        val kbps: Int,
        val bitDepth: Int,
        val sampleRate: Int,
        val lossless: Boolean,
        val recordingIdentity: String? = null,
    )

    @Serializable
    data class ModuleCard(
        val id: String,
        val name: String,
        val author: String,
        val version: String,
        val download: String,
        val lossless: Boolean,
    )

    @Serializable
    data class IndexListing(val modules: List<ModuleCard>)
}

package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.Http
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlin.concurrent.Volatile

/**
 * Stream resolution: walks device clients (ANDROID first — upstream/yt-dlp
 * guest path when ANDROID_VR adaptive URLs 403 after ~1 MiB), unlocks
 * signatureCipher via [CipherUnlockBridge], probes until one URL serves audio.
 */
object PlayerBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }
    private val resolveMutex = Mutex()

    @Volatile
    private var preferred: PlayerClient? = null

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, callback: ResolveCallback) {
        bridgeScope.launch {
            try {
                val resolved = resolveMutex.withLock { resolveInternal(videoId) }
                    ?: throw IllegalStateException("No playable stream for $videoId")
                callback.onResult(
                    json.encodeToString(StreamPayload.serializer(), resolved),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    private suspend fun resolveInternal(videoId: String): StreamPayload? {
        Innertube.ensureSessionScope()
        Innertube.ensureVisitorData()
        val errors = mutableListOf<String>()
        var sts: Int? = null
        for (client in clientOrder()) {
            if (client.needsSignatureTimestamp && sts == null) {
                sts = CipherUnlock.signatureTimestamp()
                if (sts == null) {
                    println("[PlayerBridge] no signatureTimestamp — skipping ${client.clientName}")
                    errors += "${client.clientName}: no sts"
                    continue
                }
            }
            val resolved = tryClient(videoId, client, sts, errors) ?: continue
            preferred = client
            return resolved
        }
        println("[PlayerBridge] all clients refused for $videoId: $errors")
        return null
    }

    private fun clientOrder(): List<PlayerClient> {
        val first = preferred ?: return CLIENTS
        return listOf(first) + CLIENTS.filterNot { it === first }
    }

    private suspend fun tryClient(
        videoId: String,
        client: PlayerClient,
        sts: Int?,
        errors: MutableList<String>,
    ): StreamPayload? {
        val response = try {
            playerWithBotRetry(videoId, client, sts)
        } catch (e: Innertube.UnplayableException) {
            println("[PlayerBridge] ${client.clientName}@${client.clientVersion}: unplayable: ${e.displayReason}")
            if (e.isPermanent) throw e
            errors += "${client.clientName}: ${e.displayReason}"
            return null
        } catch (e: Throwable) {
            println("[PlayerBridge] ${client.clientName}@${client.clientVersion}: error: ${e.message}")
            errors += "${client.clientName}: ${e.message}"
            return null
        }

        val formats = extractAudioFormats(response)
        if (formats.isEmpty()) {
            logEmptyFormats(client, response)
            errors += "${client.clientName}: no audio formats"
            return null
        }

        probeFormats(videoId, client, formats)?.let { return it }
        errors += "${client.clientName}: all URLs refused"
        return null
    }

    private suspend fun probeFormats(
        videoId: String,
        client: PlayerClient,
        formats: List<AudioFormat>,
    ): StreamPayload? {
        for (format in formats) {
            var url = format.url
            if (url == null && format.signatureCipher != null) {
                url = CipherUnlock.unlockCipher(videoId, format.signatureCipher)
                if (url == null) {
                    println("[PlayerBridge] ${client.clientName}: cipher unlock failed for ${format.mimeType}")
                    continue
                }
                println("[PlayerBridge] ${client.clientName}: unlocked signatureCipher")
            }
            url ?: continue
            url = patchClientVersion(url, client.clientVersion)
            val probeResult = Http.probe(url, client.mediaHeaders())
            val verdict = probeResult.classify()
            println(
                "[PlayerBridge] ${client.clientName}@${client.clientVersion}: " +
                    "probe ${format.mimeType} ${format.kbps}kbps -> status=${probeResult.status} verdict=$verdict",
            )
            if (verdict == ProbeVerdict.OK) {
                println(
                    "[PlayerBridge] resolved $videoId via ${client.clientName}@${client.clientVersion} @ ${format.kbps}kbps",
                )
                return StreamPayload(
                    url = url,
                    kbps = format.kbps,
                    mimeType = format.mimeType,
                    headers = client.mediaHeaders(),
                    clientVersion = client.clientVersion,
                )
            }
        }
        return null
    }

    private suspend fun playerWithBotRetry(
        videoId: String,
        client: PlayerClient,
        sts: Int?,
    ): JsonObject {
        try {
            return Innertube.player(videoId, client, sts)
        } catch (e: Innertube.UnplayableException) {
            if (e.isPermanent) throw e
            if (e.looksLikeBotCheck) {
                println(
                    "[PlayerBridge] ${client.clientName}@${client.clientVersion}: " +
                        "bot check (${e.displayReason}); minting fresh visitor id",
                )
                Innertube.ensureVisitorData(refresh = true)
                return Innertube.player(videoId, client, sts)
            }
            throw e
        }
    }

    private data class AudioFormat(
        val url: String?,
        val signatureCipher: String?,
        val mimeType: String,
        val kbps: Int,
    )

    private fun extractAudioFormats(response: JsonObject): List<AudioFormat> {
        val streamingData = response.o("streamingData") ?: return emptyList()
        val adaptive = streamingData.a("adaptiveFormats").orEmpty().filterIsInstance<JsonObject>()
        val legacy = streamingData.a("formats").orEmpty().filterIsInstance<JsonObject>()
        val all = (adaptive + legacy).mapNotNull { it.toPlayableFormat() }
        if (all.isEmpty()) return emptyList()
        // Prefer audio-only AAC, then any audio, then muxed MP4 (itag 18).
        val audio = all.filter { it.mimeType.startsWith("audio/") }
        val aac = audio.filter { it.mimeType.contains("mp4", ignoreCase = true) }
        val muxed = all.filter { it.mimeType.startsWith("video/mp4") }
        val candidates = when {
            aac.isNotEmpty() -> aac
            audio.isNotEmpty() -> audio
            else -> muxed
        }
        return candidates.sortedByDescending { it.kbps }
    }

    /**
     * Audio-only, or muxed MP4 that still carries AAC (`itag 18`) — the
     * remaining HTTPS guest format when adaptive is SABR-only.
     */
    private fun JsonObject.toPlayableFormat(): AudioFormat? {
        val mime = (get("mimeType") as? JsonPrimitive)?.contentOrNull ?: return null
        val audioOnly = mime.startsWith("audio/")
        val muxedAac = mime.startsWith("video/mp4") && mime.contains("mp4a", ignoreCase = true)
        if (!audioOnly && !muxedAac) return null
        val url = (get("url") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        val cipher = (get("signatureCipher") as? JsonPrimitive)?.contentOrNull
            ?: (get("cipher") as? JsonPrimitive)?.contentOrNull
        if (url == null && cipher == null) return null
        val bps = (get("bitrate") as? JsonPrimitive)?.intOrNull ?: 0
        return AudioFormat(url, cipher, mime, (bps / 1000).coerceAtLeast(1))
    }

    private fun logEmptyFormats(client: PlayerClient, response: JsonObject) {
        val sd = response.o("streamingData")
        if (sd == null) {
            println("[PlayerBridge] ${client.clientName}: no streamingData keys=${response.keys}")
            return
        }
        fun summarize(list: List<JsonObject>): String = list.take(6).joinToString { fmt ->
            val mime = (fmt["mimeType"] as? JsonPrimitive)?.contentOrNull ?: "?"
            val hasUrl = fmt["url"] != null
            val hasCipher = fmt["signatureCipher"] != null || fmt["cipher"] != null
            "$mime url=$hasUrl cipher=$hasCipher"
        }
        val adaptive = sd.a("adaptiveFormats").orEmpty().filterIsInstance<JsonObject>()
        val legacy = sd.a("formats").orEmpty().filterIsInstance<JsonObject>()
        println(
            "[PlayerBridge] ${client.clientName}: no usable formats " +
                "adaptive=${adaptive.size} [${summarize(adaptive)}] " +
                "legacy=${legacy.size} [${summarize(legacy)}]",
        )
    }

    @Serializable
    data class StreamPayload(
        val url: String,
        val kbps: Int,
        val mimeType: String,
        val headers: Map<String, String> = emptyMap(),
        val clientVersion: String = "",
    )

    private fun patchClientVersion(url: String, clientVersion: String): String =
        if ("cver=" in url) url.replace(Regex("cver=[^&]+"), "cver=$clientVersion") else url

    /**
     * ANDROID / WEB_EMBEDDED first — remaining guest HTTPS sources (often
     * muxed itag 18) once ANDROID_VR adaptive URLs 403 after 1 MiB.
     * ANDROID_VR omitted: it still mints honeypot URLs on this network.
     */
    private val CLIENTS = listOf(
        PlayerClient.ANDROID,
        PlayerClient.WEB_EMBEDDED,
        PlayerClient.ANDROID_MUSIC,
        PlayerClient.TVHTML5,
        PlayerClient.IOS,
        PlayerClient.IOS_RECENT,
    )
}

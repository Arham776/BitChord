package com.music.bitchord.data.discord

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.time.Clock
import kotlin.time.ExperimentalTime

/**
 * Discord Rich Presence payloads for the user gateway (same unofficial path
 * as upstream Kizzy). The live socket lives in Swift (`DiscordGateway`).
 */
@OptIn(ExperimentalTime::class)
object DiscordBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface TokenCallback {
        fun onResult(ok: Boolean, username: String?)
    }

    fun validateToken(token: String, callback: TokenCallback) {
        scope.launch {
            val user = runCatching {
                Http.getText(
                    "https://discord.com/api/v9/users/@me",
                    headers = mapOf(
                        "Authorization" to token,
                        "User-Agent" to "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Discord/1.0",
                    ),
                )
            }.getOrNull()
            val name = user?.let {
                runCatching {
                    json.parseToJsonElement(it).jsonObject["username"]?.jsonPrimitive?.content
                }.getOrNull()
            }
            if (name != null) {
                AppSettings.setDiscordToken(token)
                AppSettings.setDiscordUsername(name)
            }
            callback.onResult(name != null, name)
        }
    }

    fun identifyPayload(token: String): String =
        """{"op":2,"d":{"token":${jsonStr(token)},"properties":{"os":"Mac OS X","browser":"Discord Client","device":""},"compress":false,"intents":0}}"""

    fun presencePayload(
        title: String,
        artist: String,
        album: String?,
        positionMs: Long,
        durationMs: Long,
        speed: Float,
        videoId: String?,
    ): String {
        val swap = AppSettings.discordSwapTitle.value
        val detailsRaw = if (swap) artist else title
        val stateRaw = if (swap) title else artist
        val now = Clock.System.now().toEpochMilliseconds()
        val speedSafe = if (speed <= 0.01f) 1f else speed
        val start = now - (positionMs / speedSafe).toLong()
        val end = if (durationMs > 0) start + (durationMs / speedSafe).toLong() else start + 1
        val details = if (speedSafe != 1f) "$detailsRaw [${speedSafe}x]" else detailsRaw
        val activityName = AppSettings.discordActivityName.value.ifBlank { "BitChord" }
        val activityType = when (AppSettings.discordActivityType.value.lowercase()) {
            "playing" -> 0
            "streaming" -> 1
            "watching" -> 3
            "competing" -> 5
            else -> 2
        }
        val status = AppSettings.discordStatus.value.ifBlank { "online" }
        val buttons = if (!videoId.isNullOrBlank()) {
            ""","buttons":["Listen on YouTube Music","Visit BitChord"]"""
        } else ""
        return """{"op":3,"d":{"since":$now,"status":${jsonStr(status)},"afk":false,"activities":[{"name":${jsonStr(activityName)},"type":$activityType,"details":${jsonStr(details)},"state":${jsonStr(stateRaw)},"timestamps":{"start":$start,"end":$end}$buttons}]}}"""
    }

    fun heartbeatPayload(seq: Long): String = """{"op":1,"d":$seq}"""

    private fun jsonStr(s: String): String =
        "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ") + "\""
}

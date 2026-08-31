package com.music.bitchord.data.scrobbling

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.settings.AppSettings
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object LastFM {
    const val ENDPOINT = "https://ws.audioscrobbler.com/2.0/"

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun getToken(): String? {
        val body = call("auth.getToken") ?: return null
        return json.parseToJsonElement(body).jsonObject["token"]?.jsonPrimitive?.contentOrNull
    }

    fun authUrl(token: String): String {
        val key = AppSettings.lastFmApiKey.value
        return "https://www.last.fm/api/auth/?api_key=$key&token=$token"
    }

    suspend fun getSession(token: String): Pair<String, String>? {
        val body = call("auth.getSession", mapOf("token" to token)) ?: return null
        val session = json.parseToJsonElement(body).jsonObject["session"] as? JsonObject ?: return null
        val key = session["key"]?.jsonPrimitive?.contentOrNull ?: return null
        val name = session["name"]?.jsonPrimitive?.contentOrNull ?: return null
        return name to key
    }

    suspend fun updateNowPlaying(artist: String, track: String, album: String?, durationSec: Int?) {
        val extra = mutableMapOf("artist" to artist, "track" to track)
        if (!album.isNullOrBlank()) extra["album"] = album
        if (durationSec != null && durationSec > 0) extra["duration"] = durationSec.toString()
        call("track.updateNowPlaying", extra, signedSession = true)
    }

    suspend fun scrobble(artist: String, track: String, album: String?, timestampSec: Long, durationSec: Int?) {
        val extra = mutableMapOf(
            "artist" to artist,
            "track" to track,
            "timestamp" to timestampSec.toString(),
        )
        if (!album.isNullOrBlank()) extra["album"] = album
        if (durationSec != null && durationSec > 0) extra["duration"] = durationSec.toString()
        call("track.scrobble", extra, signedSession = true)
    }

    private suspend fun call(
        method: String,
        extra: Map<String, String> = emptyMap(),
        signedSession: Boolean = false,
    ): String? {
        val apiKey = AppSettings.lastFmApiKey.value
        val secret = AppSettings.lastFmSecret.value
        if (apiKey.isBlank() || secret.isBlank()) return null
        val params = mutableMapOf(
            "method" to method,
            "api_key" to apiKey,
        )
        params.putAll(extra)
        if (signedSession) {
            val sk = AppSettings.lastFmSession.value
            if (sk.isBlank()) return null
            params["sk"] = sk
        }
        val sigBase = params.entries.sortedBy { it.key }.joinToString("") { it.key + it.value } + secret
        params["api_sig"] = Md5.hex(sigBase)
        params["format"] = "json"
        return runCatching { Http.postForm(ENDPOINT, params) }.getOrNull()
    }
}

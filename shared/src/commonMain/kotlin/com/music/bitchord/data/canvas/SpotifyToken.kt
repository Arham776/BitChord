package com.music.bitchord.data.canvas

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/**
 * Bearer token for Spotify Canvas, minted from the listener's `sp_dc` cookie.
 *
 * No WebView on Apple: cookie HTTP + scraping the web player HTML. Swift may
 * also inject a harvested token via [injectAccessToken] if this returns null.
 */
object SpotifyToken {

    private const val DEFAULT_TOKEN_LIFETIME_MS = 3_600_000L

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val harvestMutex = Mutex()
    private val clientMutex = Mutex()

    @kotlin.concurrent.Volatile private var cachedAccessToken: String? = null
    @kotlin.concurrent.Volatile private var accessTokenExpiresAtMs = 0L
    @kotlin.concurrent.Volatile private var cachedClientId: String? = null
    @kotlin.concurrent.Volatile private var cachedSession: SessionInfo? = null
    @kotlin.concurrent.Volatile private var cachedClientToken: String? = null
    @kotlin.concurrent.Volatile private var clientTokenExpiresAtMs = 0L

    private data class SessionInfo(val clientVersion: String, val deviceId: String)
    private data class HarvestedToken(val token: String, val expiresAt: Long, val clientId: String?)

    /** Swift WKWebView harvest fallback — call if [accessToken] is null with a cookie set. */
    fun injectAccessToken(token: String, expiresAtMs: Long, clientId: String?) {
        if (token.isBlank()) return
        cachedAccessToken = token
        accessTokenExpiresAtMs = if (expiresAtMs > 0) expiresAtMs else canvasNowMs() + DEFAULT_TOKEN_LIFETIME_MS
        if (!clientId.isNullOrBlank()) cachedClientId = clientId
    }

    suspend fun accessToken(): String? {
        val cookie = AppSettings.spotifySpdc.value
        if (cookie.isBlank()) return null

        val now = canvasNowMs()
        cachedAccessToken?.let { if (now < accessTokenExpiresAtMs - 30_000) return it }

        return harvestMutex.withLock {
            val stillNow = canvasNowMs()
            cachedAccessToken?.let { if (stillNow < accessTokenExpiresAtMs - 30_000) return@withLock it }

            Http.setHostCookies(
                "https://open.spotify.com/",
                mapOf("sp_dc" to cookie),
            )
            val harvested = mintFromGetAccessToken()
                ?: mintFromApiToken()
                ?: scrapeFromHome()
            if (harvested == null) return@withLock null

            cachedAccessToken = harvested.token
            accessTokenExpiresAtMs = harvested.expiresAt
            harvested.clientId?.let { cachedClientId = it }
            harvested.token
        }
    }

    suspend fun clientToken(): String? = clientMutex.withLock {
        val now = canvasNowMs()
        cachedClientToken?.let { if (now < clientTokenExpiresAtMs - 30_000) return@withLock it }

        val clientId = cachedClientId ?: return@withLock null
        val session = session() ?: return@withLock null

        val payload = buildJsonObject {
            putJsonObject("client_data") {
                put("client_version", session.clientVersion)
                put("client_id", clientId)
                putJsonObject("js_sdk_data") {
                    put("device_brand", "unknown")
                    put("device_model", "unknown")
                    put("os", "ios")
                    put("os_version", "")
                    put("device_id", session.deviceId)
                    put("device_type", "smartphone")
                }
            }
        }.toString().encodeToByteArray()

        val response = runCatching {
            Http.postBytes(
                "https://clienttoken.spotify.com/v1/clienttoken",
                payload,
                "application/json",
                headers = mapOf(
                    "Accept" to "application/json",
                    "User-Agent" to CANVAS_UA,
                ),
            )
        }.getOrNull() ?: return@withLock null
        if (response.status !in 200..299 || response.body == null) return@withLock null

        val root = runCatching {
            json.parseToJsonElement(response.body.decodeToString()).jsonObject
        }.getOrNull() ?: return@withLock null
        if (root["response_type"]?.jsonPrimitive?.contentOrNull != "RESPONSE_GRANTED_TOKEN_RESPONSE") {
            return@withLock null
        }
        val granted = root["granted_token"]?.jsonObject ?: return@withLock null
        val token = granted["token"]?.jsonPrimitive?.contentOrNull ?: return@withLock null
        val ttlSeconds = granted["expires_after_seconds"]?.jsonPrimitive?.contentOrNull
            ?.toLongOrNull() ?: 3600L
        cachedClientToken = token
        clientTokenExpiresAtMs = now + ttlSeconds * 1000
        token
    }

    private suspend fun mintFromGetAccessToken(): HarvestedToken? {
        val raw = Http.getRaw(
            "https://open.spotify.com/get_access_token",
            headers = mapOf("User-Agent" to CANVAS_UA, "Accept" to "application/json"),
            query = mapOf("reason" to "transport", "productType" to "web_player"),
        )
        if (raw.status !in 200..299 || raw.body.isNullOrBlank()) return null
        return parseTokenPayload(raw.body)
    }

    private suspend fun mintFromApiToken(): HarvestedToken? {
        val raw = Http.getRaw(
            "https://open.spotify.com/api/token",
            headers = mapOf("User-Agent" to CANVAS_UA, "Accept" to "application/json"),
        )
        if (raw.status !in 200..299 || raw.body.isNullOrBlank()) return null
        return parseTokenPayload(raw.body)
    }

    private suspend fun scrapeFromHome(): HarvestedToken? {
        val raw = Http.getRaw(
            "https://open.spotify.com/",
            headers = mapOf("User-Agent" to CANVAS_UA),
        )
        val html = raw.body ?: return null
        val token = Regex(""""accessToken"\s*:\s*"([^"]+)"""").find(html)?.groupValues?.get(1)
            ?: return null
        val anonymous = Regex(""""isAnonymous"\s*:\s*(true|false)""").find(html)
            ?.groupValues?.get(1) == "true"
        if (anonymous) return null
        val expiresAt = Regex(""""accessTokenExpirationTimestampMs"\s*:\s*(\d+)""")
            .find(html)?.groupValues?.get(1)?.toLongOrNull()
            ?.takeIf { it > canvasNowMs() }
            ?: (canvasNowMs() + DEFAULT_TOKEN_LIFETIME_MS)
        val clientId = Regex(""""clientId"\s*:\s*"([^"]+)"""").find(html)?.groupValues?.get(1)
        return HarvestedToken(token, expiresAt, clientId)
    }

    private fun parseTokenPayload(body: String): HarvestedToken? {
        val root = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
        val token = root["accessToken"]?.jsonPrimitive?.contentOrNull
            ?: root["access_token"]?.jsonPrimitive?.contentOrNull
            ?: return null
        val anonymous = root["isAnonymous"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: false
        if (anonymous) return null
        val expiresAt = root["accessTokenExpirationTimestampMs"]?.jsonPrimitive?.contentOrNull
            ?.toLongOrNull()?.takeIf { it > canvasNowMs() }
            ?: (canvasNowMs() + DEFAULT_TOKEN_LIFETIME_MS)
        val clientId = root["clientId"]?.jsonPrimitive?.contentOrNull
            ?: root["client_id"]?.jsonPrimitive?.contentOrNull
        return HarvestedToken(token, expiresAt, clientId)
    }

    @OptIn(ExperimentalEncodingApi::class, ExperimentalUuidApi::class)
    private suspend fun session(): SessionInfo? {
        cachedSession?.let { return it }
        val html = runCatching {
            Http.getRaw("https://open.spotify.com", headers = mapOf("User-Agent" to CANVAS_UA)).body
        }.getOrNull() ?: return null

        val configB64 = Regex("""<script id="appServerConfig" type="text/plain">([^<]+)</script>""")
            .find(html)?.groupValues?.get(1) ?: return null
        val clientVersion = runCatching {
            val padded = configB64.padEnd(configB64.length + (4 - configB64.length % 4) % 4, '=')
            val configJson = Base64.Default.decode(padded).decodeToString()
            json.parseToJsonElement(configJson).jsonObject["clientVersion"]?.jsonPrimitive?.contentOrNull
        }.getOrNull() ?: return null

        val session = SessionInfo(clientVersion, Uuid.random().toString())
        cachedSession = session
        return session
    }
}

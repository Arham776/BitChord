package com.music.bitchord.data.http

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.timeout
import io.ktor.client.request.forms.FormDataContent
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.Parameters
import io.ktor.http.contentType
import io.ktor.utils.io.cancel
import io.ktor.utils.io.readRemaining
import kotlinx.io.readByteArray
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSHTTPCookieDomain
import platform.Foundation.NSHTTPCookieName
import platform.Foundation.NSHTTPCookieOriginURL
import platform.Foundation.NSHTTPCookiePath
import platform.Foundation.NSHTTPCookieSecure
import platform.Foundation.NSHTTPCookieStorage
import platform.Foundation.NSHTTPCookieValue
import platform.Foundation.NSURL

/**
 * Port of upstream `data/Http.kt`, Swift-flavoured per spec §1.2.
 *
 * Darwin URLSession strips a `Cookie` header the way OkHttp does not, so
 * WEB_REMIX cookies live in an isolated [NSHTTPCookieStorage] the API
 * client actually sends. The media client keeps storage off so googlevideo
 * never sees the session (LOGIN_REQUIRED).
 */
actual object Http {

    private const val COOKIE_GROUP = "group.com.example.bitchord"

    private val apiCookies: NSHTTPCookieStorage =
        NSHTTPCookieStorage.sharedCookieStorageForGroupContainerIdentifier(COOKIE_GROUP)

    /** API client — non-2xx is an error for innertube POSTs/GETs. */
    private val client: HttpClient = HttpClient(Darwin) {
        engine {
            configureSession {
                HTTPShouldSetCookies = true
                HTTPCookieStorage = apiCookies
            }
        }
        install(HttpTimeout)
        expectSuccess = true
    }

    /**
     * Lenient client: cookies from [apiCookies], does not throw on non-2xx.
     * Used by Spotify canvas/token and status-aware GETs.
     */
    private val lenientClient: HttpClient = HttpClient(Darwin) {
        engine {
            configureSession {
                HTTPShouldSetCookies = true
                HTTPCookieStorage = apiCookies
            }
        }
        install(HttpTimeout)
        expectSuccess = false
    }
    private val mediaClient: HttpClient = HttpClient(Darwin) {
        engine {
            configureSession {
                HTTPShouldSetCookies = false
                HTTPCookieStorage = null
            }
        }
        install(HttpTimeout)
        expectSuccess = false
    }

    actual fun installSessionCookies(header: String?) {
        apiCookies.cookies?.let { list ->
            (list as List<*>).filterIsInstance<NSHTTPCookie>().forEach { cookie ->
                apiCookies.deleteCookie(cookie)
            }
        }
        if (header.isNullOrBlank()) return
        var installed = 0
        header.split(';').forEach { entry ->
            val name = entry.substringBefore('=').trim()
            val value = entry.substringAfter('=', "").trim()
            if (name.isEmpty() || value.isEmpty()) return@forEach
            cookieWith(name, value)?.let {
                apiCookies.setCookie(it)
                installed++
            }
        }
        println("[Http] installed $installed session cookies for WEB_REMIX")
    }

    private fun cookieWith(name: String, value: String): NSHTTPCookie? {
        val props: Map<Any?, Any> = if (name.startsWith("__Host-")) {
            mapOf(
                NSHTTPCookieName to name,
                NSHTTPCookieValue to value,
                NSHTTPCookiePath to "/",
                NSHTTPCookieSecure to "TRUE",
                NSHTTPCookieOriginURL to (NSURL(string = "https://music.youtube.com/") ?: return null),
            )
        } else {
            mapOf(
                NSHTTPCookieName to name,
                NSHTTPCookieValue to value,
                NSHTTPCookieDomain to ".youtube.com",
                NSHTTPCookiePath to "/",
                NSHTTPCookieSecure to "TRUE",
            )
        }
        return NSHTTPCookie.cookieWithProperties(props)
    }

    /** POST JSON, return the response body as text — the shape every
     *  innertube call takes. Timeouts mirror upstream's 20 s connect /
     *  30 s read budget. */
    actual suspend fun postJson(
        url: String,
        body: String,
        headers: Map<String, String>,
        query: Map<String, String>,
        timeoutMillis: Long,
    ): String = client.post(url) {
        contentType(ContentType.Application.Json)
        setBody(body)
        timeout {
            requestTimeoutMillis = timeoutMillis
            connectTimeoutMillis = 20_000
        }
        headers.forEach { (key, value) -> header(key, value) }
        query.forEach { (key, value) -> parameter(key, value) }
    }.bodyAsText()

    /** GET, return the response body as text. */
    actual suspend fun getText(
        url: String,
        headers: Map<String, String>,
        query: Map<String, String>,
        timeoutMillis: Long,
    ): String = client.get(url) {
        timeout {
            requestTimeoutMillis = timeoutMillis
            connectTimeoutMillis = 20_000
        }
        headers.forEach { (key, value) -> header(key, value) }
        query.forEach { (key, value) -> parameter(key, value) }
    }.bodyAsText()

    actual suspend fun getStatus(
        url: String,
        headers: Map<String, String>,
        query: Map<String, String>,
        timeoutMillis: Long,
    ): Int = client.get(url) {
        timeout {
            requestTimeoutMillis = timeoutMillis
            connectTimeoutMillis = 20_000
        }
        headers.forEach { (key, value) -> header(key, value) }
        query.forEach { (key, value) -> parameter(key, value) }
    }.status.value

    /** GET, return the response body as raw bytes. */
    actual suspend fun getBytes(
        url: String,
        headers: Map<String, String>,
        timeoutMillis: Long,
    ): ByteArray {
        val response = mediaClient.get(url) {
            timeout {
                requestTimeoutMillis = timeoutMillis
                connectTimeoutMillis = 20_000
            }
            headers.forEach { (key, value) -> header(key, value) }
        }
        if (response.status.value !in 200..299) {
            throw IllegalStateException("HTTP ${response.status.value}: ${response.status.description}")
        }
        return response.bodyAsBytes()
    }

    actual suspend fun postForm(
        url: String,
        fields: Map<String, String>,
        headers: Map<String, String>,
        timeoutMillis: Long,
    ): String = mediaClient.post(url) {
        timeout {
            requestTimeoutMillis = timeoutMillis
            connectTimeoutMillis = 20_000
        }
        headers.forEach { (key, value) -> header(key, value) }
        setBody(FormDataContent(Parameters.build {
            fields.forEach { (k, v) -> append(k, v) }
        }))
    }.bodyAsText()

    actual suspend fun getRaw(
        url: String,
        headers: Map<String, String>,
        query: Map<String, String>,
        timeoutMillis: Long,
    ): RawHttpText {
        val response = lenientClient.get(url) {
            timeout {
                requestTimeoutMillis = timeoutMillis
                connectTimeoutMillis = 8_000
            }
            headers.forEach { (key, value) -> header(key, value) }
            query.forEach { (key, value) -> parameter(key, value) }
        }
        val body = runCatching { response.bodyAsText() }.getOrNull()
        return RawHttpText(status = response.status.value, body = body)
    }

    actual suspend fun postBytes(
        url: String,
        body: ByteArray,
        contentType: String,
        headers: Map<String, String>,
        timeoutMillis: Long,
    ): RawHttpBytes {
        val response = lenientClient.post(url) {
            timeout {
                requestTimeoutMillis = timeoutMillis
                connectTimeoutMillis = 8_000
            }
            header("Content-Type", contentType)
            headers.forEach { (key, value) ->
                if (!key.equals("Content-Type", ignoreCase = true)) header(key, value)
            }
            setBody(body)
        }
        val bytes = runCatching { response.bodyAsBytes() }.getOrNull()
        return RawHttpBytes(status = response.status.value, body = bytes)
    }

    actual fun setHostCookies(originUrl: String, cookies: Map<String, String>) {
        val origin = NSURL(string = originUrl) ?: return
        val host = origin.host ?: return
        val domain = when {
            host.endsWith("spotify.com") -> ".spotify.com"
            host.startsWith(".") -> host
            else -> ".$host"
        }
        cookies.forEach { (name, value) ->
            if (name.isBlank() || value.isBlank()) return@forEach
            val props: Map<Any?, Any> = mapOf(
                NSHTTPCookieName to name,
                NSHTTPCookieValue to value,
                NSHTTPCookieDomain to domain,
                NSHTTPCookiePath to "/",
                NSHTTPCookieSecure to "TRUE",
            )
            NSHTTPCookie.cookieWithProperties(props)?.let { apiCookies.setCookie(it) }
        }
    }

    /**
     * A ranged GET with a short leash — upstream's stream `probe`.
     *
     * Asks for [PROBE_RANGE_BYTES] (matching StreamDownload chunk size) and
     * reads only [PROBE_READ_BYTES], then cancels. A single ask: the dual
     * second-range check false-positived on Darwin after a mid-body cancel.
     * Unlocked ANDROID URLs are expected to serve full multi-chunk downloads;
     * ANDROID_VR adaptive honeypots still fail mid-download and are last resort.
     */
    actual suspend fun probe(
        url: String,
        headers: Map<String, String>,
    ): ProbeResult {
        return try {
            val response = rangedGet(url, headers, from = 0, length = PROBE_RANGE_BYTES)
            val ct = response.contentType()?.toString()
            val status = response.status.value
            if (status in REFUSAL_CODES) {
                response.discardBody()
                return ProbeResult(status = status, contentType = ct, bodyArrived = false)
            }
            if (status !in 200..299 && status != 416) {
                response.discardBody()
                return ProbeResult(status = status, contentType = ct, bodyArrived = false)
            }
            val media = ct != null && (
                ct.startsWith("audio/") ||
                    ct.startsWith("video/mp4") ||
                    ct.startsWith("video/3gpp")
            )
            if (!media) {
                response.discardBody()
                return ProbeResult(status = status, contentType = ct, bodyArrived = false)
            }
            val bodyArrived = response.readProbeBytes()
            if (!bodyArrived) {
                return ProbeResult(status = status, contentType = ct, bodyArrived = false)
            }
            ProbeResult(status = status, contentType = ct, bodyArrived = true)
        } catch (_: Exception) {
            ProbeResult(status = -1, contentType = null, bodyArrived = false)
        }
    }

    private suspend fun rangedGet(
        url: String,
        headers: Map<String, String>,
        from: Long,
        length: Long,
    ): HttpResponse = mediaClient.get(url) {
        header("Range", "bytes=$from-${from + length - 1}")
        timeout { requestTimeoutMillis = PROBE_TIMEOUT_MS }
        headers.forEach { (key, value) -> header(key, value) }
    }

    /** Read [PROBE_READ_BYTES] then cancel — do not drain the full ranged body. */
    private suspend fun HttpResponse.readProbeBytes(): Boolean = try {
        val channel = bodyAsChannel()
        val bytes = channel.readRemaining(PROBE_READ_BYTES).readByteArray()
        channel.cancel(null)
        bytes.size >= PROBE_READ_BYTES
    } catch (_: Exception) {
        false
    }

    private suspend fun HttpResponse.discardBody() {
        try {
            bodyAsChannel().cancel(null)
        } catch (_: Exception) {
            // already closed / never opened
        }
    }

    private val REFUSAL_CODES = setOf(403, 404, 410)

    private const val PROBE_TIMEOUT_MS = 6_000L
    /** 16 KiB Range — enough to see audio/mp4, not a full megabyte before play. */
    private const val PROBE_RANGE_BYTES = 16_384L
    private const val PROBE_READ_BYTES = 16_384L
}

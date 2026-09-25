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
import platform.Foundation.NSHTTPCookiePath
import platform.Foundation.NSHTTPCookieSecure
import platform.Foundation.NSHTTPCookieStorage
import platform.Foundation.NSHTTPCookieValue
import platform.Foundation.NSURL

/**
 * Apple actual of [Http] — Ktor's Darwin engine, **one** client.
 *
 * ## Why exactly one
 *
 * Upstream's `data/Http.kt` is a single OkHttp client and its header comment is
 * entirely about why the *innertube* calls and the *media* fetch must not be
 * separate stacks: googlevideo binds a stream URL to the connection context
 * that minted it, so a media fetch that resolves to a different address family
 * than the `player` request comes back 403. `Innertube` then wires itself
 * straight into it (`engine { preconfigured = Http.client }`).
 *
 * This used to be three clients — an API one, a lenient one, and a `mediaClient`
 * with `HTTPCookieStorage = null` — kept separate on the theory that googlevideo
 * must never see the account session. That theory does not survive contact with
 * how cookies work: a cookie jar is domain-scoped, so `.youtube.com` cookies
 * cannot reach `*.googlevideo.com` in the first place, and the separation bought
 * nothing while giving up the shared connection context. The comment it replaced
 * is the one this file's is modelled on.
 *
 * `expectSuccess` is off for the shared client and strictness is applied
 * explicitly by the few calls that need it ([postJson], [getText], [getBytes]),
 * so one client can serve both the calls that treat a 4xx as an error and the
 * ones that need to read a status — [getRaw], [postBytes], [getStatus] and
 * [probe], where a 403 is the answer rather than an error.
 *
 * ## The session cookie
 *
 * Sent as a request header, like upstream. Nothing mirrors it into
 * `cookieJar` — see the note on [Http]. [cookieJar] holds provider cookies
 * only, and is scoped to the app group so it is not shared with the rest of the
 * process.
 */
actual object Http {

    private const val COOKIE_GROUP = "group.com.example.bitchord"

    private val cookieJar: NSHTTPCookieStorage =
        NSHTTPCookieStorage.sharedCookieStorageForGroupContainerIdentifier(COOKIE_GROUP)

    /**
     * The one client. `httpShouldSetCookies` stays on so provider cookies
     * written by [setHostCookies] are sent, and so a provider's own `Set-Cookie`
     * rotations are honoured across requests. Neither reaches the account
     * session: nothing writes that here, and the youtube.com cookies Google sets
     * in response to an innertube call are not credentials.
     */
    private val client: HttpClient = HttpClient(Darwin) {
        engine {
            configureSession {
                HTTPShouldSetCookies = true
                HTTPCookieStorage = cookieJar
            }
        }
        install(HttpTimeout)
        expectSuccess = false
    }

    /** Throws for a non-2xx, standing in for what `expectSuccess = true` would. */
    private fun HttpResponse.requireSuccess(what: String) {
        val code = status.value
        if (code !in 200..299) {
            error("$what: HTTP $code ${status.description}")
        }
    }

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
    }.also { it.requireSuccess("POST $url") }.bodyAsText()

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
    }.also { it.requireSuccess("GET $url") }.bodyAsText()

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

    actual suspend fun getBytes(
        url: String,
        headers: Map<String, String>,
        timeoutMillis: Long,
    ): ByteArray = client.get(url) {
        timeout {
            requestTimeoutMillis = timeoutMillis
            connectTimeoutMillis = 20_000
        }
        headers.forEach { (key, value) -> header(key, value) }
    }.also { it.requireSuccess("GET $url") }.bodyAsBytes()

    actual suspend fun postForm(
        url: String,
        fields: Map<String, String>,
        headers: Map<String, String>,
        timeoutMillis: Long,
    ): String = client.post(url) {
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
        val response = client.get(url) {
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
        val response = client.post(url) {
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
        val host = NSURL(string = originUrl)?.host ?: return
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
            val cookie = NSHTTPCookie.cookieWithProperties(props) ?: return@forEach
            // Replace rather than accumulate. A jar is keyed by name/domain/path,
            // but a `Set-Cookie` with a different path would otherwise leave the
            // stale copy eligible to be sent first, and the provider would see
            // the credential we meant to replace.
            cookieJar.cookies?.let { existing ->
                (existing as List<*>).filterIsInstance<NSHTTPCookie>()
                    .filter { it.name == cookie.name && it.domain == cookie.domain }
                    .forEach { cookieJar.deleteCookie(it) }
            }
            cookieJar.setCookie(cookie)
        }
    }

    /**
     * A ranged GET with a short leash — upstream's stream `probe`.
     *
     * The range has to be as large as the real fetch will ask for, not a token
     * one. Upstream's reasoning, which this used to get wrong by two orders of
     * magnitude:
     *
     *  > A URL minted for a session Google has reservations about serves small
     *  > ranges to anybody — enough to pass a small probe — and then refuses
     *  > the multi-megabyte ranges actual listening is made of with a 403.
     *
     * A 16 KiB probe therefore passed URLs that died on the playback path,
     * which is what "it loads and then doesn't play" is made of. This asks for
     * [PROBE_RANGE_BYTES], matching the chunk size the real read uses, and
     * insists on [PROBE_READ_BYTES] actually arriving so a response that stalls
     * after its headers is a failure too.
     *
     * The headers are the ones the media fetch will really use
     * ([PlayerClient.mediaHeaders]), so this tests the request that matters.
     *
     * Unlocked ANDROID URLs are expected to serve full multi-chunk downloads;
     * adaptive URLs that only serve the first megabyte fail here, which is the
     * point of asking for two.
     */
    actual suspend fun probe(
        url: String,
        headers: Map<String, String>,
    ): ProbeResult {
        return try {
            val response = rangedGet(url, headers, from = 0, length = PROBE_RANGE_BYTES)
            val ct = response.contentType()?.toString()
            val status = response.status.value
            if (status in REFUSAL_CODES || status !in 200..299 && status != 416) {
                response.discardBody()
                return ProbeResult(status = status, contentType = ct, bodyArrived = false)
            }
            // Audio only. Upstream requires this and a muxed `video/mp4` answer
            // is not something this engine can play, so accepting it here would
            // pass a URL the caller then has to reject.
            if (!isAudioContentType(ct)) {
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
    ): HttpResponse = client.get(url) {
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

    private fun isAudioContentType(ct: String?): Boolean = ct?.startsWith("audio/") == true

    private val REFUSAL_CODES = setOf(403, 404, 410)

    private const val PROBE_TIMEOUT_MS = 6_000L

    /**
     * Two megabytes, matching the range the engine and the read-ahead actually
     * request. A probe smaller than the real fetch cannot see a refusal the
     * real fetch would meet.
     */
    private const val PROBE_RANGE_BYTES = 2L * 1024 * 1024

    /** Enough of the answer to have to actually arrive, to catch a stalled body. */
    private const val PROBE_READ_BYTES = 16L * 1024
}

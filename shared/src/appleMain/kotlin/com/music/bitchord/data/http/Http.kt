package com.music.bitchord.data.http

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.timeout
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
import io.ktor.http.contentType
import io.ktor.utils.io.cancel
import io.ktor.utils.io.readRemaining
import kotlinx.io.readByteArray

/**
 * Port of upstream `data/Http.kt`, Swift-flavoured per spec §1.2: a single
 * Ktor `HttpClient(Darwin)` for the whole app, preserving the header/user-
 * agent logic Innertube is sensitive to. (Upstream's connection-pool sizing
 * is OkHttp-specific; the Darwin engine manages its own session pool.)
 */
actual object Http {

    /** API client — non-2xx is an error for innertube POSTs/GETs. */
    private val client: HttpClient = HttpClient(Darwin) {
        engine {
            // Session cookies are attached explicitly on WEB_REMIX browse
            // (Innertube.authHeaders). Auto-handling would also send them on
            // ANDROID player / googlevideo ranges — Google answers that with
            // LOGIN_REQUIRED, and it is the misuse we must not do.
            configureSession {
                HTTPShouldSetCookies = false
                HTTPCookieStorage = null
            }
        }
        install(HttpTimeout)
        expectSuccess = true
    }

    /**
     * Media client sharing the same Darwin engine/session pool as [client].
     * `expectSuccess` is off so a 403 probe is data, not an exception.
     * Built once — never via per-call `client.config {}`.
     */
    private val mediaClient: HttpClient = client.config { expectSuccess = false }

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
            // One 16 KiB peek. A second 1 MiB range doubled first-play latency
            // and is redundant for ANDROID itag-18: grudging VR URLs still die
            // when StreamDownload asks for the next chunk.
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

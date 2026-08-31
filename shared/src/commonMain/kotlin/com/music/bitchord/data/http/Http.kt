package com.music.bitchord.data.http

/**
 * One HTTP seam for the whole app (port of upstream `data/Http.kt` per spec
 * §1.2): a single client instance so innertube and any media fetch share the
 * connection context. Apple actual = Ktor Darwin engine; an androidMain
 * actual reappears when the Android reunification milestone lands.
 */
expect object Http {
    /** POST JSON, return the response body as text. */
    suspend fun postJson(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String

    /** GET, return the response body as text. */
    suspend fun getText(
        url: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String

    /**
     * GET, return the response body as raw bytes. Uses the same Ktor Darwin
     * engine as [probe], so it has the same TLS fingerprint that googlevideo
     * accepts. Range requests are supported via [headers].
     */
    suspend fun getBytes(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 60_000,
    ): ByteArray

    /**
     * The answer to a ranged GET: status + content type, after a few bytes of
     * body have actually arrived. This is upstream's stream `probe` — the test
     * that tells a URL that serves audio from one that 403s on the first real
     * read, before it is handed to the engine.
     */
    suspend fun probe(url: String, headers: Map<String, String> = emptyMap()): ProbeResult

    /**
     * GET that returns the status code and ignores the body. Stats pings
     * (`s.youtube.com`) answer 204; treating that as an error would drop plays.
     */
    suspend fun getStatus(
        url: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 15_000,
    ): Int

    /**
     * Darwin URLSession ignores a `Cookie` header on the request (OkHttp
     * does not). Session cookies are therefore also written into an isolated
     * `HTTPCookieStorage` the API client actually sends. No-op on engines
     * that honour the header. Never used for googlevideo.
     */
    fun installSessionCookies(header: String?)

    /** POST application/x-www-form-urlencoded. Non-2xx still returns the body. */
    suspend fun postForm(
        url: String,
        fields: Map<String, String>,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String
}

/** [Http.probe]'s verdict input; the classification happens where it is read. */
data class ProbeResult(
    val status: Int,
    val contentType: String?,
    /** Whether any body bytes arrived at all. */
    val bodyArrived: Boolean,
)

package com.music.bitchord.data.listentogether

import io.ktor.client.HttpClient
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The party client: the REST calls that get in, and the socket that stays in.
 *
 * ## Why the local clock is passed in
 *
 * [PartySession] measures the offset from the party server with a [ServerClock], and
 * that clock needs a *monotonic* local reading. This is the one place that decision
 * becomes concrete: on Apple it is
 * `ProcessInfo.processInfo.systemUptime` — seconds since boot, unaffected by the
 * wall clock, counting through deep sleep. Reading `Date()` instead would put every
 * network time adjustment, every manual time change and every DST step straight into
 * the offset, and move this device's playhead relative to everyone else's mid-track.
 * So it arrives as a lambda and the platform decides, and there is nowhere in this
 * file that a wall clock could be read by accident.
 *
 * ## Why these throw
 *
 * Every function here throws [PartyException] rather than returning a `Result`.
 *
 * A `Result` is a fine thing inside Kotlin, and a poor thing in a `suspend`
 * function: it cannot be thrown, so a caller who wants the usual `try`/`catch` around
 * a join has to unwrap it by hand at every level. It is also why these functions were
 * unreachable from the app at all — Kotlin/Native hands a Swift caller an opaque
 * boxed `Result` with no header and no `getOrNull`, so `create` was callable,
 * compiled, and useless. A throwing `suspend` function arrives in Swift as
 * `(T?, NSError?)`, which is the shape Swift already understands.
 */
class PartyClient(
    private val scope: CoroutineScope,
    private val client: HttpClient,
    /** Monotonic milliseconds. On Apple, `ProcessInfo.processInfo.systemUptime * 1000`. */
    private val localNowMs: () -> Long,
) {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    // ---- Getting in and out ------------------------------------------------

    /**
     * Create a party and join it as host.
     *
     * @throws PartyException
     */
    suspend fun create(
        base: String,
        userId: String,
        deviceId: String,
        displayName: String,
        avatarUrl: String? = null,
        autoplayEnabled: Boolean? = null,
    ): PartyMembership = post(
        base = base,
        path = "/api/parties",
        body = buildJsonObject {
            put("userId", userId)
            put("deviceId", deviceId)
            put("displayName", displayName)
            avatarUrl?.let { put("avatarUrl", it) }
            autoplayEnabled?.let { put("autoplayEnabled", it) }
        },
        serializer = PartyMembership.serializer(),
    )

    /**
     * Join an existing party. The code alone is not a credential; the token is.
     *
     * @throws PartyException
     */
    suspend fun join(
        base: String,
        code: String,
        userId: String,
        deviceId: String,
        displayName: String,
        avatarUrl: String? = null,
    ): PartyMembership = post(
        base = base,
        path = "/api/parties/$code/join",
        body = buildJsonObject {
            put("userId", userId)
            put("deviceId", deviceId)
            put("displayName", displayName)
            avatarUrl?.let { put("avatarUrl", it) }
        },
        serializer = PartyMembership.serializer(),
    )

    /**
     * Look a party up without joining it.
     *
     * Deliberately smaller than a full snapshot: enough to show a face and a name
     * before committing a device slot, and nothing that would let the holder of a
     * code act on a party they are not in.
     *
     * @throws PartyException
     */
    suspend fun preview(base: String, code: String): PartyPreview = get(
        base = base,
        path = "/api/parties/$code/preview",
        serializer = PartyPreview.serializer(),
    )

    /**
     * Leave a party.
     *
     * The token goes in the `Authorization` header and **not** in the body, which is
     * the whole content of this function. `handleLeaveParty` reads
     * `parseBearerToken(r)` and answers 401 before it looks at the party at all, so a
     * body-carried token is not a different encoding of the same request — it is a
     * request that can never succeed. The member is identified by the token: the
     * server derives the member id from the credential and removes that one, so an id
     * sent alongside it would be a second claim about who is leaving, and the one the
     * server ignores.
     *
     * @throws PartyException
     */
    suspend fun leave(base: String, code: String, token: String) {
        val response = request {
            client.post(url(base, "/api/parties/$code/leave")) { bearerAuth(token) }
        }
        if (!response.status.isSuccess()) {
            val text = response.bodyAsText()
            throw PartyException(response.status.value, errorCodeOf(text), errorMessageOf(text))
        }
    }

    /**
     * One health check, for [ServerSelection].
     *
     * [timeoutMs] is applied per call rather than being a hint: this is the check
     * that decides whether a server is *absent*, and a check with no bound would sit
     * on a half-open connection for as long as the OS takes to give up, which on a
     * listener's phone is long enough to read as the app hanging.
     */
    suspend fun probe(base: String, timeoutMs: Long): ProbeResult {
        val normalized = ServerUrl.parseAndNormalize(base).normalizedOrNull.orEmpty()
        if (normalized.isEmpty()) return ProbeResult(isOnline = false)
        val started = localNowMs()
        return try {
            val response = withTimeout(timeoutMs) { client.get("$normalized/healthz") }
            val online = response.status.isSuccess() && response.bodyAsText().contains("\"ok\":true")
            val elapsed = (localNowMs() - started).coerceAtLeast(0)
            ProbeResult(isOnline = online, latencyMs = if (online) elapsed else 0)
        } catch (_: Throwable) {
            ProbeResult(isOnline = false)
        }
    }

    // ---- Plumbing ----------------------------------------------------------

    private suspend inline fun <reified T> post(
        base: String,
        path: String,
        body: JsonObject,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): T {
        val response = request {
            client.post(url(base, path)) {
                contentType(ContentType.Application.Json)
                setBody(body.toString())
            }
        }
        if (!response.status.isSuccess()) {
            throw PartyException(response.status.value, errorCodeOf(response.bodyAsText()), errorMessageOf(response.bodyAsText()))
        }
        return json.decodeFromString(serializer, response.bodyAsText())
    }

    private suspend inline fun <reified T> get(
        base: String,
        path: String,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): T {
        val response = request { client.get(url(base, path)) }
        if (!response.status.isSuccess()) {
            throw PartyException(response.status.value, errorCodeOf(response.bodyAsText()), errorMessageOf(response.bodyAsText()))
        }
        return json.decodeFromString(serializer, response.bodyAsText())
    }

    /**
     * One HTTP call, with every transport problem turned into one exception type.
     *
     * `expectSuccess` is off, deliberately: a 409 "party full" is a *sentence* the
     * screen should show, and it arrives in the body. Letting Ktor throw on it would
     * discard the code and the message and leave the listener with "something went
     * wrong" for the one refusal that has an obvious remedy.
     */
    private suspend inline fun request(
        crossinline call: suspend () -> HttpResponse,
    ): HttpResponse = try {
        call()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        // `null` status rather than a made-up one: this is the case where the server
        // was never reached, and the difference is what decides whether another
        // server is worth trying.
        throw PartyException(null, "transport", e.message ?: e.toString())
    }

    /** The normalised base plus a path, without doubling or losing the separator. */
    private fun url(base: String, path: String): String =
        ServerUrl.parseAndNormalize(base).normalizedOrNull.orEmpty() + path

    private fun errorCodeOf(text: String): String = runCatching {
        json.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.contentOrNull.orEmpty()
    }.getOrDefault("")

    private fun errorMessageOf(text: String): String = runCatching {
        json.parseToJsonElement(text).jsonObject["message"]?.jsonPrimitive?.contentOrNull.orEmpty()
    }.getOrDefault("")

    companion object {
        /**
         * Not used: the socket pings on its own schedule, because the platform's ping
         * and the protocol's ping travel on the same timer in
         * `AppleApp/Sources/PlaybackSession/PartySocket.swift`, and a second timer
         * here would only be able to disagree with it.
         */
        const val PING_INTERVAL_MS = 5_000L
    }
}

/** A refusal from the party server, or a failure to reach it. */
class PartyException(
    val statusCode: Int?,
    val errorCode: String,
    override val message: String,
) : Exception(message) {

    /**
     * Whether another server is worth trying.
     *
     * Deliberately not "was it a 4xx" as a rule of its own: a 4xx is the server
     * *working*, saying no. Falling back would answer "no such party" by contacting
     * a different server, and a code that exists on one server can exist on another
     * as a different party.
     */
    fun isEligibleForFallback(): Boolean = when {
        statusCode == null -> true // never reached it
        errorCode == "host_only" -> false // it worked; the answer was no
        errorCode == "party_full" -> false
        errorCode == "not_found" -> false
        else -> statusCode in 500..599
    }

    /**
     * The refusal, in the portable terms [isEligibleForFallback] is written in.
     *
     * The judgement is what matters and it is shared code; "is this a
     * `ConnectException`" is a question with a different answer on every platform and
     * none of them portable, so the platform layer does the classifying and the
     * policy does not move.
     */
    fun asFailure(): PartyFailure = when {
        statusCode == null -> PartyFailure.Transport(errorCode)
        errorCode in REFUSALS -> PartyFailure.Rejected(statusCode)
        else -> PartyFailure.Server(statusCode)
    }

    private companion object {
        /** Codes that are the server working, not the server unwell. */
        val REFUSALS = setOf("host_only", "party_full", "not_found", "invalid", "forbidden", "rate_limited")
    }
}

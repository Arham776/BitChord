package com.music.bitchord.data.listentogether

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.builtins.serializer
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
 * [PartySocket] measures the offset from the party server with a [ServerClock], and
 * that clock needs a *monotonic* local reading. This is the one place that decision
 * becomes concrete: on Apple it is
 * `ProcessInfo.processInfo.systemUptime` — seconds since boot, unaffected by the
 * wall clock, counting through deep sleep. Reading `Date()` instead would put every
 * network time adjustment, every manual time change and every DST step straight into
 * the offset, and move this device's playhead relative to everyone else's mid-track.
 * So it arrives as a lambda and the platform decides, and there is nowhere in this
 * file that a wall clock could be read by accident.
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

    /** Create a party and join it as host. */
    suspend fun create(
        base: String,
        userId: String,
        deviceId: String,
        displayName: String,
        avatarUrl: String? = null,
        autoplayEnabled: Boolean? = null,
    ): Result<PartyMembership> = post(
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

    /** Join an existing party. The code alone is not a credential; the token is. */
    suspend fun join(
        base: String,
        code: String,
        userId: String,
        deviceId: String,
        displayName: String,
        avatarUrl: String? = null,
    ): Result<PartyMembership> = post(
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
     */
    suspend fun preview(base: String, code: String): Result<PartyPreview> = get(
        base = base,
        path = "/api/parties/$code/preview",
        serializer = PartyPreview.serializer(),
    )

    suspend fun leave(base: String, code: String, memberId: String, token: String): Result<Unit> = post(
        base = base,
        path = "/api/parties/$code/leave",
        body = buildJsonObject {
            put("memberId", memberId)
            put("token", token)
        },
        serializer = Unit.serializer(),
    )

    /** One health check, for [ServerSelection]. */
    suspend fun probe(base: String, timeoutMs: Long): ProbeResult {
        val normalized = ServerUrl.parseAndNormalize(base).normalizedOrNull.orEmpty()
        if (normalized.isEmpty()) return ProbeResult(isOnline = false)
        val started = localNowMs()
        return try {
            val response = client.get("$normalized/healthz")
            val online = response.status.isSuccess() && response.bodyAsText().contains("\"ok\":true")
            val elapsed = (localNowMs() - started).coerceAtLeast(0)
            ProbeResult(isOnline = online, latencyMs = if (online) elapsed else 0)
        } catch (_: Throwable) {
            ProbeResult(isOnline = false)
        }
    }

    // ---- Plumbing ----------------------------------------------------------

    private val clock = ServerClock()

    /** The measured offset from the party server, once there is one. */
    fun serverClock(): ServerClock = clock

    /**
     * Feed one completed round trip to the clock.
     *
     * Called by [PartySocket] when a pong lands. The clock lives here rather than in
     * the socket because [PartySession] and [PartySync] both read the offset, and two
     * copies of a measurement is one too many.
     */
    fun recordRoundTrip(sentAtLocalMs: Long, serverMs: Long, receivedAtLocalMs: Long) {
        clock.record(sentAtLocalMs, serverMs, receivedAtLocalMs)
    }

    private suspend inline fun <reified T> post(
        base: String,
        path: String,
        body: JsonObject,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): Result<T> = try {
        val response = client.post(ServerUrl.parseAndNormalize(base).normalizedOrNull.orEmpty() + path) {
            contentType(ContentType.Application.Json)
            setBody(body.toString())
        }
        val text = response.bodyAsText()
        if (response.status.isSuccess()) {
            Result.success(json.decodeFromString(serializer, text))
        } else {
            Result.failure(PartyException(response.status.value, errorCodeOf(text), errorMessageOf(text)))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(PartyException(0, "transport", e.message.orEmpty()))
    }

    private suspend inline fun <reified T> get(
        base: String,
        path: String,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): Result<T> = try {
        val response = client.get(ServerUrl.parseAndNormalize(base).normalizedOrNull.orEmpty() + path)
        val text = response.bodyAsText()
        if (response.status.isSuccess()) {
            Result.success(json.decodeFromString(serializer, text))
        } else {
            Result.failure(PartyException(response.status.value, errorCodeOf(text), errorMessageOf(text)))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(PartyException(0, "transport", e.message.orEmpty()))
    }

    private fun errorCodeOf(text: String): String = runCatching {
        json.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.contentOrNull.orEmpty()
    }.getOrDefault("")

    private fun errorMessageOf(text: String): String = runCatching {
        json.parseToJsonElement(text).jsonObject["message"]?.jsonPrimitive?.contentOrNull.orEmpty()
    }.getOrDefault("")

    companion object {
        /** How often to measure the clock. Five seconds is a third of a tolerance. */
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

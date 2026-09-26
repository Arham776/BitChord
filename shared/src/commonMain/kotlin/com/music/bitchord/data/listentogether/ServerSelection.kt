package com.music.bitchord.data.listentogether

/** How a server is, as far as the last check could tell. */
enum class ServerHealth { UNKNOWN, CHECKING, ONLINE, OFFLINE }

/** One round trip to a server's health endpoint. */
data class ProbeResult(val isOnline: Boolean, val latencyMs: Long = 0L)

/**
 * Which server this device should talk to, and why.
 *
 * [Unconfigured] exists because the shipped default is empty. A party server is a
 * deployment somebody has to run, and no address is baked into the build, so
 * "nothing was probed" is a real state — and a *distinct* one from
 * [ServerConnection.Offline]. Collapsing them would show a listener who has not
 * entered a server yet a connection that failed, which is a lie about something
 * that was never attempted.
 */
sealed interface ServerConnection {

    data object Unconfigured : ServerConnection

    data object Checking : ServerConnection

    /** The built-in server answered. */
    data class DefaultOnline(val latencyMs: Long) : ServerConnection

    /** The listener's own server answered. */
    data class CustomOnline(val latencyMs: Long) : ServerConnection

    /**
     * The listener's own server did not answer, and the built-in one did.
     *
     * [latencyMs] is the **built-in** server's, deliberately and this is the whole
     * subtlety: the address the user is about to be on is the one whose time this
     * is. Reporting the failed probe's time would put a number on screen that
     * describes a connection that does not exist.
     */
    data class CustomFallback(val latencyMs: Long) : ServerConnection

    /** Every server that could be tried has been tried, and none answered. */
    data object Offline : ServerConnection
}

val ServerConnection.health: ServerHealth
    get() = when (this) {
        ServerConnection.Unconfigured -> ServerHealth.UNKNOWN
        ServerConnection.Checking -> ServerHealth.CHECKING
        is ServerConnection.DefaultOnline, is ServerConnection.CustomOnline, is ServerConnection.CustomFallback ->
            ServerHealth.ONLINE
        ServerConnection.Offline -> ServerHealth.OFFLINE
    }

val ServerConnection.latencyMs: Long?
    get() = when (this) {
        is ServerConnection.DefaultOnline -> latencyMs
        is ServerConnection.CustomOnline -> latencyMs
        is ServerConnection.CustomFallback -> latencyMs
        ServerConnection.Unconfigured, ServerConnection.Checking, ServerConnection.Offline -> null
    }

/** Whether this device is on a server other than the one it was configured with. */
val ServerConnection.isFallback: Boolean get() = this is ServerConnection.CustomFallback

/** What was decided, and what to actually dial. */
data class ServerChoice(
    /** The normalised address to use. Empty when [ServerConnection.Unconfigured]. */
    val base: String,
    val connection: ServerConnection,
)

/**
 * Choosing a server, and when it is legitimate to stop trying one.
 *
 * ## The preference is not "the one that answers"
 *
 * It is **the configured one, always, and the built-in one only when the configured
 * one cannot be reached at all.** Those come apart, and the difference matters: a
 * party lives on one server, so a listener who pointed the app at their own has
 * said where their parties are. Silently moving them to a different server the
 * moment theirs hiccups would not be resilience, it would be a party that stops
 * existing and reappears elsewhere without anybody being told. So the fallback
 * needs a *positive* failure, not a slow answer.
 *
 * A slow server is used as it is. A party tolerates a second of latency far better
 * than it tolerates landing on a server with no memory of the party.
 */
object ServerSelection {

    /** How long one health check may take before it counts as a failure. */
    const val DEFAULT_SERVER_TIMEOUT_MS = 30_000L
    const val CUSTOM_SERVER_TIMEOUT_MS = 8_000L
    const val HEALTH_TIMEOUT_MS = 5_000L

    /**
     * Decide which server to use.
     *
     * Probes are supplied rather than performed so the decision can be tested
     * exhaustively — the interesting cases are all "the first probe failed", and
     * those are the ones that need a server to be down.
     *
     * A custom address that does not parse is treated as **absent**, not as an
     * error. A typo in the address box should cost the listener their own server
     * for the session, not the feature: falling through to the built-in one is
     * correct behaviour here, and reporting the address as broken is done by the
     * screen that owns the box, which can point at the character.
     */
    suspend fun resolve(
        customServer: String,
        defaultServer: String,
        probe: suspend (base: String, timeoutMs: Long) -> ProbeResult,
    ): ServerChoice {
        val custom = ServerUrl.parseAndNormalize(customServer).normalizedOrNull.orEmpty()
        val builtIn = ServerUrl.parseAndNormalize(defaultServer).normalizedOrNull.orEmpty()

        // A custom server that *is* the built-in one is not a custom server. Without
        // this, typing the built-in address into the box would probe it twice per
        // refresh and report a fallback that is not one.
        val hasCustom = custom.isNotEmpty() && custom != builtIn

        if (hasCustom) {
            val customProbe = probe(custom, CUSTOM_SERVER_TIMEOUT_MS)
            if (customProbe.isOnline) {
                return ServerChoice(custom, ServerConnection.CustomOnline(customProbe.latencyMs))
            }
            if (builtIn.isEmpty()) {
                // Nothing to fall back to. Reported as the configured server being
                // offline rather than as a fallback, because there is no second
                // address to have fallen back from.
                return ServerChoice(custom, ServerConnection.Offline)
            }
            val builtInProbe = probe(builtIn, DEFAULT_SERVER_TIMEOUT_MS)
            return if (builtInProbe.isOnline) {
                ServerChoice(builtIn, ServerConnection.CustomFallback(builtInProbe.latencyMs))
            } else {
                ServerChoice(builtIn, ServerConnection.Offline)
            }
        }

        if (builtIn.isEmpty()) return ServerChoice("", ServerConnection.Unconfigured)
        val builtInProbe = probe(builtIn, DEFAULT_SERVER_TIMEOUT_MS)
        return if (builtInProbe.isOnline) {
            ServerChoice(builtIn, ServerConnection.DefaultOnline(builtInProbe.latencyMs))
        } else {
            ServerChoice(builtIn, ServerConnection.Offline)
        }
    }

    /**
     * The server a party switch should use when the invite names none.
     *
     * The raw configured address is passed in rather than the resolved one, and the
     * difference is load-bearing: a switch with no explicit target — a typed code,
     * entered while already live in a party — has to land on whichever server idle
     * operations resolve to. Handed `""` instead, a switch to a party that lives on
     * the built-in server is treated as a malformed target and refused outright.
     */
    fun switchTarget(
        inviteServer: String?,
        customServer: String,
        idleServer: String,
    ): String {
        val fromInvite = ServerUrl.parseAndNormalize(inviteServer).normalizedOrNull
        if (!fromInvite.isNullOrEmpty()) return fromInvite
        val custom = ServerUrl.parseAndNormalize(customServer).normalizedOrNull.orEmpty()
        return custom.ifEmpty { idleServer }
    }
}

/**
 * Why a request failed, in the terms that decide whether another server is worth
 * trying.
 *
 * Deliberately not a `Throwable` type hierarchy. "Is this a `ConnectException`" is
 * a question with a different answer on every platform and none of them are
 * portable; the judgement is what matters, so the judgement is what is named, and
 * the platform's networking layer does the classifying.
 */
sealed interface PartyFailure {

    /**
     * The request never got an answer, or never got an answer that was ours.
     *
     * Refused, unresolvable, unreachable, timed out. A different server might
     * answer, so trying one is the only thing that can help.
     */
    data class Transport(val detail: String = "") : PartyFailure

    /** The server answered, and said 5xx. It is unwell rather than absent. */
    data class Server(val statusCode: Int) : PartyFailure

    /** The server answered, and said 4xx. It is here, and it said no. */
    data class Rejected(val statusCode: Int) : PartyFailure

    /** Anything else: a parse failure, a bug, a cancelled call. */
    data class Other(val detail: String = "") : PartyFailure
}

/**
 * Whether a failure justifies trying a different server.
 *
 * ## Why 4xx is not eligible, and this is the sharp edge of the whole policy
 *
 * A 4xx is the server **working**. It received the request, understood it, and
 * declined. Falling back would answer "that party does not exist" by contacting a
 * different server — which turns one clear "no such party" into a confusing
 * attempt somewhere else, and can land the listener in a *different party that
 * happens to share the code*. A 403 on a full party is not a reason to try the
 * built-in server; the party is full, full is the answer, and it will be the
 * answer on the second server too.
 *
 * So: transport failures and 5xx, which are about the server's condition, are
 * eligible. Everything else is an answer.
 */
fun PartyFailure.isEligibleForFallback(): Boolean = when (this) {
    is PartyFailure.Transport -> true
    is PartyFailure.Server -> statusCode in 500..599
    is PartyFailure.Rejected -> false
    is PartyFailure.Other -> false
}

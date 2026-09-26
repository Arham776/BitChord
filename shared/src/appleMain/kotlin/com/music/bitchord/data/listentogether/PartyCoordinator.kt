package com.music.bitchord.data.listentogether

import kotlin.concurrent.Volatile
import com.music.bitchord.BuildDefaults
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The one place a Listen Together session is owned.
 *
 * ## Why this exists
 *
 * The pieces underneath are all portable and separately tested — the clock, the
 * server choice, the protocol, the state machine — but three of them need a
 * [CoroutineScope] and an [HttpClient], and a SwiftUI view is the wrong place to
 * construct either. So the scope, the client, the session and the current party live
 * here, and the view is told what the state is and asked to do things.
 *
 * That also makes the lifetime explicit. A party's lifetime is the *user's*, not the
 * view's: rotating a Mac window, or a sheet being dismissed, must not end it. A
 * scope owned by a view would.
 *
 * ## The local clock
 *
 * A lambda, and not a wall clock. It has to be monotonic and boot-relative, and the
 * only portable clock that is both is a choice each platform makes differently.
 */
object PartyCoordinator {

    private val scope = CoroutineScope(SupervisorJob())
    private val client = HttpClient(Darwin)

    /** One client, not one per call: each would bring its own connection pool. */
    private val api = PartyClient(scope = scope, client = client, localNowMs = { localNowMs() })

    /** One client, not one per call: each would bring its own connection pool. */
    /** Monotonic, boot-relative. On Apple, `ProcessInfo.processInfo.systemUptime * 1000`. */
    @Volatile
    var localNowMs: () -> Long = { 0L }

    private val _session = PartySession()
    val session: PartySession get() = _session

    private val _server = MutableStateFlow(ServerChoice("", ServerConnection.Unconfigured))
    val server: StateFlow<ServerChoice> = _server

    /** The listener's own server, empty when they have not named one. */
    @Volatile
    var customServer: String = ""

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError

    private var socketJob: Job? = null

    /** The party this device is in, once joined. */
    @Volatile
    var membership: PartyMembership? = null
        private set

    // ---- Server ------------------------------------------------------------

    /**
     * Ask the server, and record which one answered.
     *
     * Suspends, so a screen can show a spinner against it rather than guessing.
     */
    suspend fun resolveServer() {
        val choice = ServerSelection.resolve(customServer, BuildDefaults.LISTEN_TOGETHER_SERVER) { base, timeoutMs ->
            api.probe(base, timeoutMs)
        }
        _server.value = choice
        if (choice.base.isNotEmpty()) customServer = choice.base
    }

    /** The address to offer as the default in the server field. */
    fun defaultServer(): String = customServer.ifEmpty { BuildDefaults.LISTEN_TOGETHER_SERVER }

    /**
     * Whether an address is usable, and what is wrong with it if not.
     *
     * Returns null when it is fine, and a sentence rather than an enum name,
     * because this string is shown in a text field's footer and a SwiftUI view
     * cannot switch over a Kotlin sealed hierarchy without a bridge for each case.
     */
    fun serverProblem(raw: String): String? = when (val result = ServerUrl.parseAndNormalize(raw)) {
        is ServerUrlValidationResult.Valid -> {
            if (result.normalizedUrl.isEmpty()) "Enter a server address to use Listen Together." else null
        }

        is ServerUrlValidationResult.Invalid -> when (result.error) {
            ServerUrlError.Whitespace -> "That address contains a space."
            ServerUrlError.InvalidScheme -> "Only http and https addresses work."
            ServerUrlError.InvalidHost -> "That does not look like a server address."
            ServerUrlError.InvalidPort -> "That port number is not valid."
            ServerUrlError.InvalidPath -> "That address cannot contain a . or .. path."
            ServerUrlError.HasQuery -> "Remove the ? and everything after it."
            ServerUrlError.HasFragment -> "Remove the # and everything after it."
        }
    }

    // ---- Joining and leaving ----------------------------------------------

    suspend fun create(nickname: String, autoplay: Boolean): Result<PartyMembership> =
        attempt { api.create(base(), userId(), deviceId(), nickname, autoplayEnabled = autoplay) }

    suspend fun join(code: String, nickname: String): Result<PartyMembership> =
        attempt { api.join(base(), code.trim().uppercase(), userId(), deviceId(), nickname) }

    suspend fun preview(code: String): Result<PartyPreview> = attempt { api.preview(base(), code.trim().uppercase()) }

    suspend fun leave(): Result<Unit> {
        val current = membership
        val base = _session.serverBase
        val result = if (current == null) {
            Result.success(Unit)
        } else {
            attempt { api.leave(base, current.code, current.you.memberId, current.token) }
        }
        disconnect()
        return result
    }

    /** Join an invite link, using the server it names when it names one. */
    suspend fun joinInvite(link: String, nickname: String): Result<PartyMembership> {
        val invite = JamInviteLink.parseInvite(link)
            ?: return Result.failure(PartyException(null, "bad_invite", "That is not a party invite."))
        if (!invite.serverUrl.isNullOrEmpty()) customServer = invite.serverUrl
        _server.value = ServerChoice(base(), ServerConnection.Checking)
        return join(invite.code, nickname)
    }

    /** The shareable link for the party this device is in. */
    fun inviteLink(): String? {
        val code = membership?.code ?: return null
        val base = _session.serverBase
        val server = JamInviteLink.sanitizeServerUrl(base) ?: return null
        return "bitchord://party/$code?server=$server"
    }

    private suspend fun <T> attempt(block: suspend () -> Result<T>): Result<T> = try {
        val result = block()
        _lastError.value = result.exceptionOrNull()?.message
        result
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        _lastError.value = e.message
        Result.failure(PartyException(null, "transport", e.message.orEmpty()))
    }

    // ---- The session -------------------------------------------------------

    /** Begin a party and stay in it. */
    fun connect(membership: PartyMembership) {
        disconnect()
        this.membership = membership
        _session.begin(serverBase = base(), code = membership.code)
        socketJob = scope.launch {
            PartySocketBridge.connect(base(), membership.code, membership.token) { json ->
                val frame = PartyFrameCodec.decode(json) ?: return@connect
                // A pong is the only frame that measures anything, and it is the only
                // thing that can turn the party server's clock into this device's.
                if (frame is PartyFrame.Pong) {
                    _session.recordPong(frame.clientMs, frame.serverMs, localNowMs())
                }
                val applied = _session.apply(frame)
                if (applied is PartySession.Applied.Queue) _session.queueRefetchSent()
            }
        }
    }

    fun disconnect() {
        socketJob?.cancel()
        socketJob = null
        PartySocketBridge.stop()
        _session.reset()
        membership = null
    }

    // ---- Controls ----------------------------------------------------------

    /**
     * Send a control, if this device is allowed to.
     *
     * Returns false rather than sending anyway when the party is locked and this
     * device is not the host. The server would refuse it — and refusing is correct —
     * but a button that appears to work and does nothing is worse than a disabled
     * one, and the party-wide setting is known here.
     */
    fun control(action: String, payload: kotlinx.serialization.json.JsonObject = kotlinx.serialization.json.JsonObject(emptyMap())): Boolean {
        val state = _session.current
        if (!state.inParty || !state.canControl) return false
        PartySocketBridge.sendRaw(PartyOutgoingCodec.encode(PartyOutgoing.Control(action, payload)))
        return true
    }

    fun askForQueue() {
        PartySocketBridge.sendRaw(PartyOutgoingJson.syncQueue())
    }

    fun askForState() {
        PartySocketBridge.sendRaw(PartyOutgoingJson.sync())
    }

    // ---- Identity ----------------------------------------------------------

    private fun base(): String = _server.value.base.ifEmpty { defaultServer() }

    private fun userId(): String = "apple"

    /**
     * This device's id.
     *
     * A constant for now, and it is a real limitation rather than an oversight: the
     * server identifies a member by (userId, deviceId), so two Macs signed into one
     * party with the same id are the same member and the second is refused. A
     * per-install identifier persisted in the settings tier is the fix, and it belongs
     * with the rest of the account identity rather than invented here.
     */
    private fun deviceId(): String = "apple"

    /** For tests and for teardown. */
    fun shutdown() {
        disconnect()
        scope.cancel()
        client.close()
    }
}

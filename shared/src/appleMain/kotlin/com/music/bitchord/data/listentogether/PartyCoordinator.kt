package com.music.bitchord.data.listentogether

import kotlin.concurrent.Volatile
import com.music.bitchord.BuildDefaults
import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.settings.InstallId
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import kotlinx.coroutines.CancellationException
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
 * ## What this owns, and why it is one object
 *
 * The parts underneath are portable and separately tested — the clock, the server
 * choice, the protocol, the state machine, the drift policy. What they do not own is
 * the three things that need a [CoroutineScope] and an [HttpClient], and that is
 * here. But the reason this is *one* object rather than a service the views construct
 * is the part that matters: **there is exactly one party session, one socket and one
 * clock on a device.**
 *
 * The port had it otherwise — a session and a socket in here, and a second session,
 * a second socket and a second clock in the player binding — and the two would race
 * for the same transport, with whichever was started last silently winning. Nothing
 * in the port would have said so. The player binding is now a *reader* of
 * [session]; it never opens a socket and never holds state of its own.
 *
 * ## Why the lifetime is not a view's
 *
 * A party's lifetime is the listener's. Rotating a Mac window, a sheet being
 * dismissed, the Listen Together screen being one tab among four — none of those end
 * it, and most of what listening together looks like is the screen being somewhere
 * else. A scope owned by a view would end the party every time the listener glanced
 * at their library.
 *
 * ## Why the REST calls throw rather than return a [Result]
 *
 * Because `Result` does not survive the trip to Swift. Kotlin/Native exports a
 * suspend function as a completion handler, but `Result<T>` arrives as an opaque
 * boxed object with no header, no protocol and no `getOrNull` — so every one of
 * these calls was callable and useless from the one place that has to call them. A
 * throwing suspend function arrives as `(T?, NSError?)`, which is exactly the shape
 * Swift already understands. The cost is that the error arrives as an `NSError`
 * rather than as a typed value, which is why [PartyException] keeps the machine-
 * readable code and the status on it.
 *
 * ## Why every one of them is annotated `@Throws`
 *
 * Because a Kotlin/Native function only turns a thrown exception into an `NSError` if
 * it declares that it throws, and a function that throws without saying so does
 * something much worse than fail: the exception crosses the Objective-C boundary as
 * an *unexpected* one and the process is terminated. A party that is full — the single
 * most ordinary refusal this feature has — would have taken the app down with it.
 *
 * So `@Throws(PartyException::class, CancellationException::class)` below is not
 * decoration. It is the difference between "the party is full" appearing in a text
 * field and the app disappearing. `CancellationException` is listed because Kotlin
 * requires it on a suspending function's `@Throws`, and it is the right thing to
 * declare anyway: a listener who walks out of the screen cancels the join.
 */
object PartyCoordinator {

    // ---- What the platform provides ----------------------------------------

    private val scope = CoroutineScope(SupervisorJob())

    /** One client, not one per call: each would bring its own connection pool. */
    private val client = HttpClient(Darwin)

    private val api = PartyClient(scope = scope, client = client, localNowMs = { localNowMs() })

    /**
     * Monotonic, boot-relative milliseconds.
     *
     * A lambda, and not a wall clock. It has to be monotonic, and the only portable
     * clock that is boot-relative as well is a choice each platform makes
     * differently: on Apple it is `ProcessInfo.processInfo.systemUptime * 1000`.
     *
     * The default is zero rather than a guess, so a platform that forgets to set it
     * gets a clock that measures nothing and says so — which is visibly wrong — rather
     * than one that measures against a wall clock and is wrong by however much the
     * network has moved since.
     */
    @Volatile
    var localNowMs: () -> Long = { 0L }

    /**
     * Told whenever anything a screen can see has changed.
     *
     * A callback rather than an exposed [StateFlow] because SwiftUI cannot observe a
     * `StateFlow`: it is not an `Observable`, and there is no subscription a Swift
     * view can make. So the one object that owns the state pushes it out, and the
     * Swift side stores it on a `@Observable` holder. This is the same shape as every
     * other Kotlin-to-Swift bridge in this app.
     */
    @Volatile
    var onStateChanged: ((PartyState) -> Unit)? = null

    // ---- State --------------------------------------------------------------

    private val _session = PartySession()

    /** The party, as this device understands it. The one session. */
    val session: PartySession get() = _session

    /** The same thing as a flow, for portable callers that collect it. */
    val state: StateFlow<PartyState> get() = _session.state

    private val _server = MutableStateFlow(ServerChoice("", ServerConnection.Unconfigured))
    val server: StateFlow<ServerChoice> = _server.asStateFlow()

    /**
     * Whether a call is in flight.
     *
     * Every screen that offers a button which reaches the server needs to know to
     * disable it, and "the button did nothing" is the alternative.
     */
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    /** The last thing that went wrong, for a screen to show rather than a spinner. */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private var socketJob: Job? = null

    /**
     * The party this device is in.
     *
     * Public because it holds the **token**, which is the credential for the socket
     * and the only thing that makes this device's membership real. The token is never
     * displayed and never leaves the process.
     */
    @Volatile
    var membership: PartyMembership? = null
        private set

    // ---- The listener's own settings ---------------------------------------

    /**
     * The server this device talks to.
     *
     * Read from the settings tier on every access rather than cached, so that a
     * listener who edits the address on the server sheet sees it take effect on the
     * next resolve without this object having to be told it changed.
     */
    private fun configuredServer(): String = AppSettings.listenTogetherServer.value

    /** The address to offer as the default in the server field. */
    fun defaultServer(): String {
        val entered = configuredServer()
        return if (entered.isNotEmpty()) entered else BuildDefaults.LISTEN_TOGETHER_SERVER
    }

    /**
     * Whether an address is usable, and what is wrong with it if not.
     *
     * A sentence rather than an enum name, because this string is shown in a text
     * field's footer and a SwiftUI view cannot switch over a Kotlin sealed hierarchy
     * without a bridge per case. Null when it is fine.
     */
    fun serverProblem(raw: String): String? = when (val result = ServerUrl.parseAndNormalize(raw)) {
        is ServerUrlValidationResult.Valid ->
            if (result.normalizedUrl.isEmpty()) "Enter a server address to use Listen Together." else null

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

    /**
     * Which server should be used, and whether it answered.
     *
     * Probes the configured server and, only if that one cannot be reached at all,
     * the built-in one. See [ServerSelection] for why a configured server is never
     * traded away for a working one.
     */
    suspend fun resolveServer() {
        val entered = configuredServer()
        val builtIn = BuildDefaults.LISTEN_TOGETHER_SERVER
        _busy.value = true
        publish()
        try {
            val choice = ServerSelection.resolve(entered, builtIn) { base, timeoutMs ->
                api.probe(base, timeoutMs)
            }
            _server.value = choice
            // Written back so the address the listener is *on* is the one remembered.
            // Canonicalised, not raw, so the two spellings of one server stop being
            // two servers in the box.
            val settled = if (choice.base.isNotEmpty() && !choice.isFallback) choice.base else entered
            if (settled != entered) AppSettings.setListenTogetherServer(settled)
        } finally {
            _busy.value = false
            publish()
        }
    }

    // ---- Joining and leaving ----------------------------------------------

    /**
     * Start a party, and join it as host.
     *
     * @throws PartyException if the server refuses, or cannot be reached
     */
    @Throws(PartyException::class, CancellationException::class)
    suspend fun create(nickname: String, autoplay: Boolean): PartyMembership {
        val identity = identity(nickname)
        val result = call {
            api.create(base(), identity.userId, identity.deviceId, identity.displayName, identity.avatarUrl, autoplay)
        }
        join(result)
        return result
    }

    /**
     * Join an existing party by its code.
     *
     * Leaving a current party first is deliberate rather than incidental: a device in
     * two parties at once would be counted twice against two member limits and would
     * be told about playbacks it is not playing. A failure to leave is not allowed to
     * stop the switch — the target is what the listener asked for, and the server
     * expires an abandoned membership on its own — but it is recorded, because
     * "you are still in the old party" is worth knowing.
     */
    @Throws(PartyException::class, CancellationException::class)
    suspend fun join(code: String, nickname: String): PartyMembership {
        val cleaned = code.trim().uppercase()
        leave()
        val identity = identity(nickname)
        val result = call {
            api.join(base(), cleaned, identity.userId, identity.deviceId, identity.displayName, identity.avatarUrl)
        }
        join(result)
        return result
    }

    /**
     * Join from an invite link, using the server it names when it names one.
     *
     * The link's server wins over everything else, including the address the listener
     * has configured, and including the built-in one: a link is somebody telling this
     * device where their party is. A link naming an address that cannot be parsed
     * falls through to the configured server rather than failing the join outright.
     */
    @Throws(PartyException::class, CancellationException::class)
    suspend fun joinInvite(link: String, nickname: String): PartyMembership {
        val invite = JamInviteLink.parseInvite(link)
            ?: throw PartyException(null, "bad_invite", "That is not a party invite.")
        val target = ServerSelection.switchTarget(
            inviteServer = invite.serverUrl,
            customServer = configuredServer(),
            idleServer = base(),
        )
        if (target.isNotEmpty()) {
            AppSettings.setListenTogetherServer(target)
            _server.value = ServerChoice(target, ServerConnection.Checking)
        }
        return join(invite.code, nickname)
    }

    /**
     * Look a party up without joining it.
     *
     * Used to show who is in a party and whether there is room *before* a device slot
     * is committed, which is the difference between a listener being told a party is
     * full and being refused after tapping Join.
     *
     * @throws PartyException if the code is not one, or the server cannot be reached
     */
    @Throws(PartyException::class, CancellationException::class)
    suspend fun preview(code: String): PartyPreview = call {
        api.preview(base(), code.trim().uppercase())
    }

    /**
     * Leave the party this device is in, and tell the server.
     *
     * Local teardown happens whether or not the call succeeds: a listener who has
     * walked out of the room should be out of the room on this device regardless of
     * whether a LAN router heard them. The server forgets an abandoned membership on
     * its own, so a failed leave is a stale slot rather than a lasting one.
     */
    @Throws(PartyException::class, CancellationException::class)
    suspend fun leave() {
        val current = membership
        val base = _session.serverBase
        disconnect()
        if (current == null) return
        call { api.leave(base, current.code, current.token) }
    }

    /**
     * The shareable link for the party this device is in.
     *
     * A `bitchord://` link rather than the server's web invite, because the listener
     * is inviting people who have the app: the link opens straight into the join
     * sheet. The server is carried in the link, so the people it reaches do not have
     * to have configured a server of their own to find the party.
     */
    fun inviteLink(): String? {
        val code = membership?.code ?: return null
        val server = JamInviteLink.sanitizeServerUrl(_session.serverBase) ?: return null
        return "bitchord://party/$code?server=$server"
    }

    // ---- The socket --------------------------------------------------------

    /**
     * Open the socket for [party] and stay in it until it ends.
     *
     * Every frame goes through [PartySession.apply], and the three things that are
     * true of a frame rather than of the state are done here: a pong measures the
     * clock, a queue the session does not hold is asked for again, and a `bye` ends
     * the session rather than the socket.
     */
    private fun join(party: PartyMembership) {
        disconnect()
        membership = party
        val base = party.serverBase()
        _session.begin(serverBase = base, code = party.code)
        publish()
        socketJob = scope.launch {
            PartySocketBridge.connect(base, party.code, party.token) { json ->
                onFrame(json)
            }
        }
    }

    /**
     * The server this membership was granted by.
     *
     * Taken from the session rather than recomputed, and the reason is a bug worth
     * naming: the address in [ServerSelection] is the result of a *probe*, and a
     * probe can land on the built-in server while the listener is joined to their
     * own. Opening the socket against the probe's answer rather than the one the
     * membership came from connects to a server that has never heard of this party.
     */
    private fun PartyMembership.serverBase(): String =
        ServerUrl.parseAndNormalize(_server.value.base).normalizedOrNull
            ?.takeIf { it.isNotEmpty() }
            ?: base()

    private fun onFrame(json: String) {
        val frame = PartyFrameCodec.decode(json) ?: return
        if (frame is PartyFrame.Pong) {
            _session.recordPong(frame.clientMs, frame.serverMs, localNowMs())
        }
        val applied = _session.apply(frame)
        if (applied is PartySession.Applied.Queue) _session.queueRefetchSent()
        if (applied is PartySession.Applied.Left) {
            // A `bye` is a decision, so the membership goes with it. The token is for
            // a session that has ended, and keeping it would leave a credential lying
            // around for a party this device is no longer in.
            membership = null
            socketJob = null
        }
        publish()
    }

    /** End the socket and the session, and forget the membership. */
    fun disconnect() {
        socketJob?.cancel()
        socketJob = null
        PartySocketBridge.stop()
        _session.reset()
        membership = null
        publish()
    }

    // ---- Controls ----------------------------------------------------------

    /**
     * Send a control, if this device is allowed to.
     *
     * The one gate every control goes through, and the reason is a control that
     * appears to work and does nothing: the party-wide "host only" setting is known
     * here, so a device that is not allowed to drive the music can say so rather
     * than send a frame the server will refuse. The server enforces the same rule —
     * this is what the app *shows*, not what makes it true.
     */
    private fun send(frame: PartyOutgoing): Boolean {
        val state = _session.current
        if (!state.inParty) return false
        if (frame !is PartyOutgoing.Ping && frame !is PartyOutgoing.Report && !state.canControl) return false
        PartySocketBridge.sendRaw(PartyOutgoingCodec.encode(frame))
        return true
    }

    fun play(): Boolean = send(PartyOutgoingCodec.play())

    fun pause(): Boolean = send(PartyOutgoingCodec.pause())

    fun seek(positionMs: Long): Boolean = send(PartyOutgoingCodec.seek(positionMs))

    fun setTrack(track: PartyTrack): Boolean = send(PartyOutgoingCodec.setTrack(track))

    fun next(): Boolean = send(PartyOutgoingCodec.next())

    fun previous(): Boolean = send(PartyOutgoingCodec.previous())

    fun queueAdd(tracks: List<PartyTrack>, playNext: Boolean = false): Boolean =
        send(PartyOutgoingCodec.queueAdd(tracks, playNext))

    fun queueRemove(videoId: String): Boolean = send(PartyOutgoingCodec.queueRemove(videoId))

    fun queueClear(): Boolean = send(PartyOutgoingCodec.queueClear())

    fun queueMove(fromIndex: Int, toIndex: Int): Boolean =
        send(PartyOutgoingCodec.queueMove(fromIndex, toIndex))

    fun setQueue(items: List<PartyTrack>, queueIndex: Int): Boolean =
        send(PartyOutgoingCodec.setQueue(items, queueIndex))

    fun setAutoplay(enabled: Boolean): Boolean = send(PartyOutgoingCodec.setAutoplay(enabled))

    fun setHostOnlyControl(enabled: Boolean): Boolean =
        send(PartyOutgoingCodec.setHostOnlyControl(enabled))

    fun setMaxMembers(count: Int): Boolean = send(PartyOutgoingCodec.setMaxMembers(count))

    fun kick(memberId: String): Boolean = send(PartyOutgoingCodec.kick(memberId))

    /** Tell the party where this device is. Diagnostic; the server only logs it. */
    fun report(positionMs: Long, isPlaying: Boolean) {
        PartySocketBridge.sendRaw(PartyOutgoingJson.report(positionMs, isPlaying))
    }

    /** Ask for a fresh state frame, for a screen that suspects it has gone stale. */
    fun askForState() {
        PartySocketBridge.sendRaw(PartyOutgoingJson.sync())
    }

    /** Ask for a fresh queue frame. */
    fun askForQueue() {
        PartySocketBridge.sendRaw(PartyOutgoingJson.syncQueue())
    }

    // ---- Identity ----------------------------------------------------------

    /**
     * The address every REST call and the socket go to.
     *
     * The resolved one when there is one, and the listener's configured address when
     * there is not. Read live rather than cached, so an address edited on the server
     * sheet is used by the very next call rather than the one after a re-resolve.
     */
    private fun base(): String {
        val resolved = _server.value.base
        if (resolved.isNotEmpty() && _server.value.connection != ServerConnection.Offline) return resolved
        val fallback = defaultServer()
        return ServerUrl.parseAndNormalize(fallback).normalizedOrNull.orEmpty()
    }

    /**
     * Who this device is to the server.
     *
     * The device id is this install's, and the user id is a digest of the account when
     * there is one. See [PartyIdentityFactory] for why the two are separate and why
     * the account is optional.
     */
    private fun identity(nickname: String): PartyIdentity {
        val account = AppSettings.partyAccount.value
        return PartyIdentityFactory.resolve(
            deviceId = InstallId.get(),
            nickname = nickname,
            accountName = account?.name,
            accountEmail = account?.email,
            accountAvatarUrl = account?.avatarUrl,
        )
    }

    // ---- Plumbing ----------------------------------------------------------

    /**
     * Run one server call, recording the outcome and the busy flag.
     *
     * Busy around the whole call rather than inside each one so a screen cannot
     * re-enter: a listener who taps Join twice gets one call and one answer, and the
     * second tap is refused rather than racing the first to create two parties.
     */
    private suspend inline fun <T> call(crossinline block: suspend () -> T): T {
        _busy.value = true
        publish()
        return try {
            val value = block()
            _lastError.value = null
            value
        } catch (e: CancellationException) {
            throw e
        } catch (e: PartyException) {
            _lastError.value = e.message
            throw e
        } catch (e: Throwable) {
            val failure = PartyException(null, "transport", e.message ?: e.toString())
            _lastError.value = failure.message
            throw failure
        } finally {
            _busy.value = false
            publish()
        }
    }

    /** Hand the current state to whoever is listening. */
    private fun publish() {
        onStateChanged?.invoke(_session.current)
    }

    /** For teardown. Closes the client and cancels the scope for good. */
    fun shutdown() {
        disconnect()
        onStateChanged = null
        scope.cancel()
        client.close()
    }
}

/** Whether [ServerChoice] landed on a fallback rather than on what was configured. */
private val ServerChoice.isFallback: Boolean get() = connection.isFallback

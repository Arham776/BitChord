package com.music.bitchord.data.listentogether

import kotlin.concurrent.Volatile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * What this device knows about the party it is in, and how that changes.
 *
 * ## This is the whole client, minus the socket
 *
 * A socket delivers frames; this decides what they mean. The split is the reason the
 * interesting half is testable: every rule below can be exercised by handing it a
 * frame, with no server, no network and no timing.
 *
 * ## The one rule that matters most
 *
 * A state frame is applied only if its `seq` is **strictly greater** than the one
 * already held. Not greater-or-equal. The server re-sends the same state on every
 * heartbeat, so an equal frame is not new information — and treating it as one would
 * reset the playhead to the position captured when the frame was *first* sent, which
 * is a drift of one heartbeat per heartbeat. A party would sound fine and be wrong by
 * a growing amount.
 *
 * The second rule: the queue is refetched when the state's `queueSeq` is ahead of the
 * copy held, and **never** otherwise. It travels separately and rarely, because it is
 * large, near-constant, and would otherwise be paid for on somebody's mobile data
 * every few seconds forever.
 */
class PartySession {

    private val _state = MutableStateFlow(PartyState())
    val state: StateFlow<PartyState> = _state.asStateFlow()

    val current: PartyState get() = _state.value

    // ---- The clock ---------------------------------------------------------
    //
    // It lives here rather than in the socket because the state machine and the player
    // binding both read the offset, and two copies of a measurement is one too many.
    private val clock = ServerClock()

    /** The offset from the party server's clock, once a pong has landed. */
    fun serverClock(): ServerClock = clock

    /**
     * Record one completed round trip.
     *
     * Called on a pong, with the local reading stamped on the outgoing ping and the
     * local reading when the answer arrived. Nothing else can establish the offset,
     * and without it a party's position is a guess.
     *
     * The two facts it produces are published into [PartyState] rather than left on
     * the clock alone, because "is this device in time with the party" is the first
     * thing a screen shows and a value buried in a collaborator object is not
     * something an observing view can be told about.
     */
    fun recordPong(sentAtLocalMs: Long, serverMs: Long, receivedAtLocalMs: Long) {
        clock.record(sentAtLocalMs, serverMs, receivedAtLocalMs)
        _state.update {
            it.copy(clockSynced = clock.synced, roundTripMs = clock.roundTripMs)
        }
    }

    /** Where the party is, on this device's clock. Zero until the first pong lands. */
    fun correctedPosition(playback: PartyPlayback, localNowMs: Long): Long =
        clock.positionFor(playback.positionMs, playback.anchorMs, localNowMs)

    /**
     * Whether a fresh queue is needed.
     *
     * Checked *before* a refetch rather than after, so two state frames arriving
     * close together produce one refetch rather than two. A burst of controls — three
     * people hitting next at once — is exactly when a naive version refetches three
     * times.
     */
    @Volatile
    private var refetchQueued = false

    /**
     * The `seq` of the last state applied, or null when none has been.
     *
     * Nullable rather than read off [PartyState.playback], and that is the fix for a
     * bug worth naming: the held state starts as a default with `seq = 0`, so a gate
     * reading `held.seq` cannot tell "already at 0" from "nothing applied yet", and
     * the very first frame from a server whose first `seq` is also 0 is dropped. A
     * device that joins a party already in progress and never hears about a single
     * subsequent change is a worse failure than any of the ones this feature has.
     */
    @Volatile
    private var appliedSeq: Long? = null

    /** The server address this session is bound to. Immutable while in a party. */
    @Volatile
    var serverBase: String = ""
        private set

    @Volatile
    var code: String = ""
        private set

    /** What a frame changed, so the caller can react without diffing the whole state. */
    sealed interface Applied {
        data object Nothing : Applied
        data object Members : Applied
        data object Queue : Applied
        data object Playback : Applied
        data object Left : Applied
    }

    fun begin(serverBase: String, code: String) {
        this.serverBase = serverBase
        this.code = code
        appliedSeq = null
        refetchQueued = false
        // Connecting, not live: [PartyConnection.LIVE] arrives with the first frame,
        // and until then there is no party to be in. A screen that showed a party
        // immediately would be showing a thing that has not been confirmed to exist.
        _state.value = PartyState(inParty = true, connection = PartyConnection.CONNECTING)
    }

    fun reset() {
        serverBase = ""
        code = ""
        appliedSeq = null
        refetchQueued = false
        clock.reset()
        _state.value = PartyState()
    }

    /**
     * Apply one frame, and report what it changed.
     *
     * Returns [Applied.Nothing] for a frame that was correctly ignored, so a caller
     * can tell "nothing happened" from "nothing arrived" — which is the difference
     * between a quiet party and a dead socket.
     */
    fun apply(frame: PartyFrame): Applied = when (frame) {
        is PartyFrame.Welcome -> {
            _state.update {
                it.copy(
                    inParty = true,
                    connection = PartyConnection.LIVE,
                    you = frame.you,
                    members = frame.party.members,
                    maxMembers = frame.party.maxMembers,
                    hostOnlyControl = frame.party.hostOnlyControl,
                    playback = frame.party.playback,
                    queue = frame.party.queue,
                    lastServerMs = frame.serverMs,
                    // A welcome carries a full snapshot, so the held copy is current
                    // by definition. Saying otherwise would make the very first
                    // state frame trigger a redundant refetch.
                    error = null,
                )
            }
            refetchQueued = false
            appliedSeq = frame.party.playback.seq
            Applied.Members
        }

        is PartyFrame.State -> applyState(frame)
        is PartyFrame.Queue -> {
            // The answer to a pending request. Clearing the flag here rather than at
            // the call site is what makes a duplicate refetch impossible: the request
            // and its answer are the same event seen twice.
            refetchQueued = false
            _state.update { it.copy(queue = frame.queue, lastServerMs = frame.serverMs, needsQueueRefetch = false) }
            Applied.Queue
        }

        is PartyFrame.Members -> {
            _state.update {
                it.copy(
                    members = frame.members,
                    maxMembers = frame.maxMembers,
                    hostOnlyControl = frame.hostOnlyControl,
                    lastServerMs = frame.serverMs,
                )
            }
            refetchQueued = false
            Applied.Members
        }

        is PartyFrame.Activity -> {
            _state.update { it.copy(activity = PartyActivity(frame.action, frame.by, frame.atMs, frame.detail)) }
            Applied.Nothing
        }

        is PartyFrame.Failure -> {
            _state.update { it.copy(error = PartyError(frame.error, frame.message)) }
            Applied.Nothing
        }

        is PartyFrame.Bye -> {
            // A decision, not a disconnection, and the one thing that ends a session
            // rather than the socket. The reason is kept so the screen can say what
            // happened instead of showing a generic failure.
            _state.update {
                it.copy(
                    inParty = false,
                    connection = PartyConnection.OFFLINE,
                    error = PartyError("left", frame.reason),
                )
            }
            Applied.Left
        }

        is PartyFrame.Pong -> {
            _state.update { it.copy(lastServerMs = frame.serverMs) }
            Applied.Nothing
        }
    }

    private fun applyState(frame: PartyFrame.State): Applied {
        val incoming = frame.playback
        val held = _state.value
        val applied = appliedSeq

        // A queue the state says is newer than the copy held is a queue to ask for,
        // whichever frame happened to say so. Checked before the gate below, because a
        // heartbeat is enough to notice and not only a change of song.
        val staleQueue = incoming.queueSeq > held.queue.seq && !refetchQueued
        if (staleQueue) refetchQueued = true

        // The gate. Strictly greater, and narrow on purpose — the reason it exists at
        // all is on PartyPlayback.supersedes: the server re-sends the same state on
        // every heartbeat, so an equal frame is not new information, and applying one
        // wholesale would reset the playhead to a position captured when the frame was
        // *first* sent. It guards the playhead and nothing else, because the playhead
        // is the only thing a repeated frame would rewind; see
        // [PartyPlayback.withPartyFactsFrom] for what the rest of the frame carries.
        val isNewer = applied == null || incoming.seq > applied
        val playback = if (isNewer) incoming else held.playback.withPartyFactsFrom(incoming)

        // A refusal is answered by the party's next *word*, not by its next change.
        // The two are not the same length of time: a listener who taps next at the end
        // of a queue is told "already at the end", and then nothing about the party
        // changes for as long as the song plays. Clearing only on a newer `seq` would
        // leave that sentence on screen for the rest of the track, complaining about
        // something five seconds ago.
        _state.update {
            it.copy(
                playback = playback,
                lastServerMs = frame.serverMs,
                needsQueueRefetch = staleQueue,
                error = null,
            )
        }
        if (isNewer) appliedSeq = incoming.seq
        return when {
            staleQueue -> Applied.Queue
            isNewer -> Applied.Playback
            else -> Applied.Nothing
        }
    }

    /** Called once a refetch has actually been sent, so the next stale frame asks again. */
    fun queueRefetchSent() {
        refetchQueued = false
        _state.update { it.copy(needsQueueRefetch = false) }
    }
}

/** Whether the socket to the party server is up, as far as this device can tell. */
enum class PartyConnection {
    /** Not in a party, or the socket is not up. */
    OFFLINE,

    /** Joined, and waiting for the first frame to confirm the party exists. */
    CONNECTING,

    /** A frame has arrived: the party is real and this device is in it. */
    LIVE,
}

/** Everything this device knows, in one value. */
data class PartyState(
    val inParty: Boolean = false,
    /**
     * This device's own member record, or null before the first frame.
     *
     * Named as upstream names it, and deliberately not `self`: a Kotlin property
     * called `self` is exported to Swift as an Objective-C property *also* called
     * `self`, where it collides with the language's own and becomes unreachable. It
     * still compiles on the Kotlin side, so the trap is silent until something tries
     * to read it from a view.
     */
    val you: PartyMember? = null,
    val members: List<PartyMember> = emptyList(),
    val maxMembers: Int = 5,
    val hostOnlyControl: Boolean = false,
    val playback: PartyPlayback = PartyPlayback(),
    val queue: PartyQueue = PartyQueue(),
    val activity: PartyActivity? = null,
    val error: PartyError? = null,
    val connection: PartyConnection = PartyConnection.OFFLINE,
    /** False until the first round trip; the playhead is a guess until then. */
    val clockSynced: Boolean = false,
    /** How long the last measured round trip took. Zero until [clockSynced]. */
    val roundTripMs: Long = 0,
    /** The server's clock at the last frame, for a rough offset before a pong lands. */
    val lastServerMs: Long = 0,
    /** Set on the frame that noticed a stale queue, cleared once it is asked for. */
    val needsQueueRefetch: Boolean = false,
) {
    val host: PartyMember? get() = members.firstOrNull { it.isHost }

    val isHost: Boolean get() = you?.isHost == true

    /**
     * This device's member id, or empty before the first frame.
     *
     * What a member list compares against to mark the row that is you, since a list
     * of members carries no other way to tell.
     */
    val myMemberId: String get() = you?.memberId.orEmpty()

    /** Whether [member] is this device. False while [myMemberId] is empty. */
    fun isMe(member: PartyMember): Boolean = myMemberId.isNotEmpty() && myMemberId == member.memberId

    /**
     * Whether this device may drive the music.
     *
     * The host may always; anybody else only when the party is not locked. Read
     * from the *server's* setting rather than a local one, because a device that
     * disagrees with the server about this is a device whose controls appear to work
     * and do nothing.
     */
    val canControl: Boolean get() = isHost || !hostOnlyControl

    /**
     * The negative of [canControl], which is the form a view actually wants.
     *
     * Both are provided because they are asked in opposite shapes — "may I" when
     * deciding whether to send, "am I locked out" when deciding whether to disable a
     * button — and a view that has to write `!state.canControl` at each call site is
     * a view that will get one of them wrong.
     *
     * This can go true under a listener mid-party: the host is reassigned when the
     * host leaves, and everything reading it has to follow.
     */
    val controlsLocked: Boolean get() = inParty && !canControl

    /**
     * Whether there is room for one more device.
     *
     * Over members rather than over *connected* members, deliberately: somebody
     * whose socket dropped is still holding their slot, and letting a sixth person in
     * would push somebody out of a party they never left.
     */
    val hasRoom: Boolean get() = members.size < maxMembers

    val isFull: Boolean get() = !hasRoom

    /** The host's display name, or empty when the host is not resolvable yet. */
    val hostName: String get() = host?.name.orEmpty()

    /** Whether the party is at its member limit, for a full party to read as full. */
    fun isFullFor(joining: Boolean): Boolean = joining && isFull
}

/** A refusal, in the terms the screen can act on. */
data class PartyError(val code: String, val message: String)

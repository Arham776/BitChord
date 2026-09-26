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
        _state.value = PartyState(inParty = true)
    }

    fun reset() {
        serverBase = ""
        code = ""
        appliedSeq = null
        refetchQueued = false
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
                    self = frame.you,
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
            _state.update { it.copy(inParty = false, error = PartyError("left", frame.reason)) }
            Applied.Left
        }

        is PartyFrame.Pong -> {
            _state.update { it.copy(lastServerMs = frame.serverMs) }
            Applied.Nothing
        }
    }

    private fun applyState(frame: PartyFrame.State): Applied {
        val incoming = frame.playback
        val applied = appliedSeq
        // The gate. Strictly greater, and the reason is on PartyPlayback.supersedes:
        // the server re-sends the same state on every heartbeat, so an equal frame is
        // not new information, and applying one would reset the playhead to a
        // position captured when the frame was *first* sent.
        if (applied != null && incoming.seq <= applied) return Applied.Nothing

        val queueStale = incoming.queueSeq > _state.value.queue.seq
        val shouldRefetch = queueStale && !refetchQueued
        if (shouldRefetch) refetchQueued = true

        // A refusal is cleared by the next state, not left to time out: the party
        // moving on is the answer to "only the host can do that", and a stale refusal
        // left on screen is a complaint about something that is no longer true.
        _state.update {
            it.copy(
                playback = incoming,
                lastServerMs = frame.serverMs,
                needsQueueRefetch = shouldRefetch,
                error = null,
            )
        }
        appliedSeq = incoming.seq
        return if (shouldRefetch) Applied.Queue else Applied.Playback
    }

    /** Called once a refetch has actually been sent, so the next stale frame asks again. */
    fun queueRefetchSent() {
        refetchQueued = false
        _state.update { it.copy(needsQueueRefetch = false) }
    }
}

/** Everything this device knows, in one value. */
data class PartyState(
    val inParty: Boolean = false,
    val self: PartyMember? = null,
    val members: List<PartyMember> = emptyList(),
    val maxMembers: Int = 5,
    val hostOnlyControl: Boolean = false,
    val playback: PartyPlayback = PartyPlayback(),
    val queue: PartyQueue = PartyQueue(),
    val activity: PartyActivity? = null,
    val error: PartyError? = null,
    /** The server's clock at the last frame, for a rough offset before a pong lands. */
    val lastServerMs: Long = 0,
    /** Set on the frame that noticed a stale queue, cleared once it is asked for. */
    val needsQueueRefetch: Boolean = false,
) {
    val host: PartyMember? get() = members.firstOrNull { it.isHost }

    val isHost: Boolean get() = self?.isHost == true

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

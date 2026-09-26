package com.music.bitchord.data.listentogether

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The party server's wire format, one-for-one.
 *
 * The server speaks camelCase for exactly this reason — it has no other client —
 * so these carry no `@SerialName` and will not need any. If a field ever has to be
 * renamed on one side, rename it on both rather than papering over the difference
 * here; the protocol is documented in `backend/README.md` and that document is the
 * contract.
 */

/**
 * A song as the party knows it.
 *
 * Deliberately *not* `Song`. What a party shares is which track is playing and
 * where the playhead is; how each device gets the audio — which source answered,
 * at what quality, from the network or from a download — stays that device's own
 * business. Two people in a party can be on entirely different sources and still be
 * in the same place in the same song, and keeping this type small is what
 * guarantees that.
 */
@Serializable
data class PartyTrack(
    val videoId: String,
    val title: String = "",
    val artist: String = "",
    val thumbnailUrl: String? = null,
    val durationMs: Long? = null,
    /** Preserves the queue's shared manual/AutoPlay section boundary. */
    val fromAutoplay: Boolean = false,
) {
    /**
     * Whether two queue entries are the same track.
     *
     * By video id alone, and the reason is worth stating: a party can have the same
     * song queued twice from two different searches, and treating those as
     * different rows is how a queue ends up with a duplicate nobody asked for.
     * Title and artist are for display and can legitimately differ between two
     * catalogue entries for one recording.
     */
    fun sameTrack(other: PartyTrack): Boolean = videoId == other.videoId
}

/** One signed-in device in the party, as every other device sees it. */
@Serializable
data class PartyMember(
    val memberId: String,
    val userId: String = "",
    val displayName: String = "",
    val avatarUrl: String? = null,
    val isHost: Boolean = false,
    /** Whether they are currently holding a socket — not whether they are still in. */
    val connected: Boolean = false,
    val joinedAtMs: Long = 0,
    val lastSeenMs: Long = 0,
) {
    /**
     * What to call this person.
     *
     * A fallback to a shortened id rather than to nothing: a party with a nameless
     * member renders as a blank row, and a blank row in a list of people reads as
     * a bug rather than as somebody who has not set a name.
     */
    val name: String
        get() = displayName.ifBlank { memberId.take(6).uppercase() }
}

/**
 * Where the party is, as of a server timestamp.
 *
 * [positionMs] is not a current position. It is the position at [anchorMs], and it
 * only becomes a current position once the reader adds the time since — see
 * [ServerClock.positionFor]. That indirection is the entire sync mechanism: a frame
 * delayed by 300 ms carries an anchor 300 ms older and still lands this device in
 * exactly the right place.
 */
@Serializable
data class PartyPlayback(
    /**
     * Bumped by the server on every change. A state whose [seq] is not greater than
     * the one already applied is dropped unread — which is what makes two people
     * hitting pause at the same moment settle rather than oscillate.
     */
    val seq: Long = 0,
    val track: PartyTrack? = null,
    /**
     * Bumped only when the queue's *contents* change, and deliberately the only
     * thing about the queue that rides along with the state.
     *
     * The queue itself travels as [PartyQueue], separately and rarely. This frame is
     * re-sent to every device every few seconds forever, and a queue inside it would
     * be large, near-constant, and paid for continuously on somebody's mobile data.
     * So all that arrives here is a number to compare against the copy already held.
     */
    val queueSeq: Long = 0,
    val queueLength: Int = 0,
    val queueIndex: Int = -1,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0,
    val anchorMs: Long = 0,
    /** The server's own reading of [positionMs] at the instant it sent the frame. */
    val effectivePositionMs: Long = 0,
    val updatedBy: String? = null,
    /** Member who selected this track; stable across pause, play and seek. */
    val startedBy: String? = null,
    /**
     * A snapshot of their name, so attribution survives that member leaving.
     *
     * Carried rather than looked up, because "Artist — Song" in the now-playing
     * line has to still read correctly ten minutes after the person who picked it
     * closed the app, and a lookup would render a blank.
     */
    val startedByName: String? = null,
    /** Party-wide, so a connected listener can refill AutoPlay on host loss. */
    val autoplayEnabled: Boolean = false,
    val updatedAtMs: Long = 0,
) {
    /** The queue entry currently playing, when there is one. */
    val currentTrack: PartyTrack? get() = track

    /**
     * Whether this frame is worth applying over what is already held.
     *
     * Strictly greater, not greater-or-equal. The server re-sends the same state on
     * every heartbeat, so an equal frame is not new information — and treating it
     * as one would reset the local playhead to a position captured when the frame
     * was *first* sent, which is a drift of one heartbeat per heartbeat.
     */
    fun supersedes(applied: PartyPlayback?): Boolean =
        applied == null || seq > applied.seq
}

/**
 * This state, with everything except the playhead taken from [newer].
 *
 * ## Why the split is here and not in the state machine
 *
 * A playback state carries two kinds of fact, and the server moves them on different
 * schedules. Its `PlaybackState.touch` — which is what increments `seq` — is called for
 * a change of track, transport or position. Its `touchQueue`, which increments
 * `queueSeq`, is called for a change to the queue. And `SetAutoplay` increments
 * **neither**. So `seq` is a *playhead* version, not a version of the whole struct.
 *
 * A client that gates the entire struct on `seq` therefore drops exactly the changes
 * `seq` does not track, and the symptom is quiet and long-lived: a host switches
 * AutoPlay off, the server accepts it and broadcasts it, and every other device goes on
 * showing AutoPlay on until the song happens to change.
 *
 * So the gate is applied to the playhead alone and these fields are taken from every
 * state frame. They are safe to take because none of them is derived from a position.
 *
 * [effectivePositionMs] is deliberately *not* among them. The server recomputes it on
 * every broadcast, so a repeated frame's copy of it is a snapshot taken when that frame
 * was built; this device's own corrected position — `ServerClock.positionFor` over
 * `positionMs` and `anchorMs` — is both later and measured on this device's own clock,
 * and two positions to choose from is how a playhead ends up fighting itself.
 */
fun PartyPlayback.withPartyFactsFrom(newer: PartyPlayback): PartyPlayback = copy(
    autoplayEnabled = newer.autoplayEnabled,
    queueLength = newer.queueLength,
    queueIndex = newer.queueIndex,
    queueSeq = newer.queueSeq,
)

/**
 * The party's running order, which travels on its own schedule.
 *
 * Sent whole when a device joins — there is no other way for it to learn the list —
 * and after that only when it actually changes. [seq] is how a device knows its
 * copy is stale: every state frame carries the server's current one, so a missed
 * update is noticed on the very next heartbeat rather than lived with until
 * somebody presses something.
 */
@Serializable
data class PartyQueue(
    val seq: Long = 0,
    val index: Int = -1,
    val items: List<PartyTrack> = emptyList(),
) {
    val isEmpty: Boolean get() = items.isEmpty()

    /** The entry at [index], or null when the index is out of range or unset. */
    val current: PartyTrack? get() = items.getOrNull(index)
}

@Serializable
data class PartySnapshot(
    val code: String = "",
    val createdAtMs: Long = 0,
    val maxMembers: Int = 5,
    /**
     * Whether only the host may drive the music here.
     *
     * Defaulted false so a party on a server that predates the setting reads as the
     * shared free-for-all this feature shipped as, rather than as locked.
     */
    val hostOnlyControl: Boolean = false,
    val members: List<PartyMember> = emptyList(),
    val playback: PartyPlayback = PartyPlayback(),
    val queue: PartyQueue = PartyQueue(),
    val serverMs: Long = 0,
) {
    val host: PartyMember? get() = members.firstOrNull { it.isHost }

    /**
     * Whether there is room for one more device.
     *
     * Counted over members rather than over *connected* members, deliberately: a
     * member whose socket has dropped is still holding their slot, and letting a
     * sixth person in would push somebody out of a party they never left.
     */
    val hasRoom: Boolean get() = members.size < maxMembers

    val isFull: Boolean get() = !hasRoom
}

/**
 * Who is in a party, to somebody who has not joined it.
 *
 * Deliberately smaller than [PartySnapshot]: enough to show a face and a name
 * before committing a device slot, and nothing that would let the holder of a code
 * act on a party they are not in.
 */
@Serializable
data class PartyPreview(
    val code: String = "",
    val hostName: String = "",
    val memberCount: Int = 0,
    val maxMembers: Int = 5,
    val isFull: Boolean = false,
    val members: List<PartyPreviewMember> = emptyList(),
) {
    /** Whether joining is even worth offering. */
    val joinable: Boolean get() = !isFull && code.isNotBlank()
}

@Serializable
data class PartyPreviewMember(
    val displayName: String = "",
    val avatarUrl: String? = null,
    val isHost: Boolean = false,
)

/** The answer to a create or a join: the code, and this device's key to it. */
@Serializable
data class PartyMembership(
    val code: String,
    val token: String,
    val you: PartyMember,
    val party: PartySnapshot,
    val serverMs: Long = 0,
)

/** A compact local-only record of a live party action. */
@Serializable
data class PartyActivity(
    val action: String,
    val by: String,
    val atMs: Long,
    val detail: String = "",
)

@Serializable
internal data class JoinRequest(
    val userId: String,
    val deviceId: String,
    val displayName: String,
    val avatarUrl: String? = null,
    val maxMembers: Int? = null,
    val autoplayEnabled: Boolean? = null,
)

@Serializable
internal data class ApiError(
    @SerialName("error") val code: String = "",
    val message: String = "",
)

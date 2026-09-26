package com.music.bitchord.data.listentogether

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * The socket's wire format.
 *
 * Read off the Go server's own `backend/protocol` and `backend/main.go` rather than
 * inferred from the Android client, because the server is the thing that has to be
 * satisfied and it is 110 lines long — a far shorter thing to read than 1,662 lines
 * of client guessing at it.
 *
 * Every frame is one JSON object distinguished by a `type` field, and **every frame
 * the server sends carries a `serverMs`**. That is not decoration: the client's
 * clock is the thing being measured against the server's throughout, so a frame
 * without a server reading could not be placed on the party timeline at all.
 */

/** A frame from the server. */
@Serializable
sealed interface PartyFrame {

    /** The party's own clock, on any frame. Null only where the server omitted it. */
    val serverMs: Long

    /** The first thing sent after the socket opens, and the only full party state. */
    @Serializable
    @SerialName("welcome")
    data class Welcome(
        val you: PartyMember,
        val party: PartySnapshot,
        override val serverMs: Long = 0,
    ) : PartyFrame

    /** Where the party is. Re-sent on every heartbeat, so [PartyPlayback.seq] is the gate. */
    @Serializable
    @SerialName("state")
    data class State(
        val playback: PartyPlayback = PartyPlayback(),
        override val serverMs: Long = 0,
    ) : PartyFrame

    /** The running order. Sent whole on join, and after that only when it changes. */
    @Serializable
    @SerialName("queue")
    data class Queue(
        val queue: PartyQueue = PartyQueue(),
        override val serverMs: Long = 0,
    ) : PartyFrame

    /**
     * Who is here.
     *
     * A separate frame rather than something in [State] because membership changes on
     * its own schedule — somebody's phone locking is not a playback event, and
     * folding it into the heartbeat would put a list of people on every device's
     * metered connection every few seconds.
     */
    @Serializable
    @SerialName("members")
    data class Members(
        val members: List<PartyMember> = emptyList(),
        val maxMembers: Int = 5,
        val hostOnlyControl: Boolean = false,
        override val serverMs: Long = 0,
    ) : PartyFrame

    /**
     * The answer to a ping, echoing [clientMs] so the two legs of the round trip can
     * be told apart.
     */
    @Serializable
    @SerialName("pong")
    data class Pong(
        val clientMs: Long = 0,
        override val serverMs: Long = 0,
    ) : PartyFrame

    /** A refusal. [error] is the machine-readable code, [message] is for a person. */
    @Serializable
    @SerialName("error")
    data class Failure(
        val error: String = "",
        val message: String = "",
        override val serverMs: Long = 0,
    ) : PartyFrame

    /**
     * The server is closing the socket, and says why.
     *
     * A distinct frame rather than a plain disconnect because the two mean opposite
     * things to the client: a plain close is worth retrying, and this is a decision.
     * Being kicked and being dropped are not the same event, and treating them alike
     * is how a removed listener watches a reconnect loop that is refused every time.
     */
    @Serializable
    @SerialName("bye")
    data class Bye(
        val reason: String = "",
        override val serverMs: Long = 0,
    ) : PartyFrame

    /** Something somebody did, in words a person can read. */
    @Serializable
    @SerialName("activity")
    data class Activity(
        val action: String = "",
        val by: String = "",
        val detail: String = "",
        val atMs: Long = 0,
        override val serverMs: Long = 0,
    ) : PartyFrame
}

/** A frame the client sends. */
sealed interface PartyOutgoing {

    /**
     * Measure the clock.
     *
     * [clientMs] is the local monotonic reading stamped on the way out, echoed back
     * on the [PartyFrame.Pong]. The server does not interpret it and does not need
     * to — it is a token that comes back.
     */
    data class Ping(val clientMs: Long) : PartyOutgoing

    /** Ask for a fresh state frame. Cheap, and the only way to get one on demand. */
    data object Sync : PartyOutgoing

    /** Ask for a fresh queue frame. */
    data object SyncQueue : PartyOutgoing

    /**
     * Report this device's own playhead.
     *
     * Diagnostic only — the server logs drift and never acts on it. Sent anyway,
     * because a party whose members silently disagree is the failure nobody can
     * diagnose afterwards.
     */
    data class Report(val positionMs: Long, val isPlaying: Boolean) : PartyOutgoing

    /** Drive the party. [action] is one of the `Action` constants below. */
    data class Control(val action: String, val payload: JsonObject) : PartyOutgoing

    companion object {
        const val PLAY = "play"
        const val PAUSE = "pause"
        const val SEEK = "seek"
        const val SET_TRACK = "setTrack"
        const val SET_QUEUE = "setQueue"
        const val QUEUE_ADD = "queueAdd"
        const val QUEUE_REMOVE = "queueRemove"
        const val QUEUE_CLEAR = "queueClear"
        const val QUEUE_MOVE = "queueMove"
        const val NEXT = "next"
        const val PREVIOUS = "previous"
        const val KICK = "kick"
        const val SET_MAX_MEMBERS = "setMaxMembers"
        const val SET_AUTOPLAY = "setAutoplay"
        const val SET_HOST_ONLY_CONTROL = "setHostOnlyControl"
    }
}

/** Building the frames the client sends. */
object PartyOutgoingCodec {

    fun encode(frame: PartyOutgoing): String = when (frame) {
        is PartyOutgoing.Ping -> buildJsonObject {
            put("type", "ping")
            put("clientMs", frame.clientMs)
        }.toString()

        PartyOutgoing.Sync -> buildJsonObject { put("type", "sync") }.toString()
        PartyOutgoing.SyncQueue -> buildJsonObject { put("type", "syncQueue") }.toString()

        is PartyOutgoing.Report -> buildJsonObject {
            put("type", "report")
            put("positionMs", frame.positionMs)
            put("isPlaying", frame.isPlaying)
        }.toString()

        is PartyOutgoing.Control -> buildJsonObject {
            put("type", "control")
            put("action", frame.action)
            // The payload is merged rather than nested, because the server reads its
            // control fields off the frame itself (`frame["positionMs"]`), not off a
            // sub-object. Nesting them would produce a frame that parses and is
            // silently ignored.
            frame.payload.forEach { (key, value) -> put(key, value) }
        }.toString()
    }

    // ---- Control payloads --------------------------------------------------
    //
    // Field names are the server's, read out of its `applyControl`. They are not
    // guessable: `queueAdd` takes `track` for one song and `tracks` for several, and
    // `setAutoplay` takes `enabled` while `seek` takes `positionMs`.

    fun play() = control(PartyOutgoing.PLAY, buildJsonObject { })

    fun pause() = control(PartyOutgoing.PAUSE, buildJsonObject { })

    fun seek(positionMs: Long) = control(PartyOutgoing.SEEK, buildJsonObject {
        put("positionMs", positionMs)
    })

    fun setTrack(track: PartyTrack) = control(PartyOutgoing.SET_TRACK, buildJsonObject {
        put("track", track.toJson())
    })

    fun setQueue(items: List<PartyTrack>, queueIndex: Int) = control(PartyOutgoing.SET_QUEUE, buildJsonObject {
        put("queue", kotlinx.serialization.json.buildJsonArray {
            items.forEach { add(it.toJson()) }
        })
        put("queueIndex", queueIndex)
    })

    fun queueAdd(tracks: List<PartyTrack>, playNext: Boolean = false) =
        control(PartyOutgoing.QUEUE_ADD, buildJsonObject {
            // One song goes in `track` and several in `tracks`. The server reads
            // `track` first, so sending the wrong one is silently a no-op — which is
            // why the branch is here rather than in the caller.
            if (tracks.size == 1) {
                put("track", tracks.first().toJson())
            } else {
                put("tracks", kotlinx.serialization.json.buildJsonArray { tracks.forEach { add(it.toJson()) } })
            }
            put("playNext", playNext)
        })

    /**
     * Remove by video id, not by index.
     *
     * The server accepts either, and indices shift underneath you: a party with
     * somebody else queueing between your reading the list and your sending the
     * control would remove the wrong song. The id cannot shift.
     */
    fun queueRemove(videoId: String) = control(PartyOutgoing.QUEUE_REMOVE, buildJsonObject {
        put("videoId", videoId)
    })

    fun queueClear() = control(PartyOutgoing.QUEUE_CLEAR, buildJsonObject { })

    fun queueMove(fromIndex: Int, toIndex: Int) = control(PartyOutgoing.QUEUE_MOVE, buildJsonObject {
        put("fromIndex", fromIndex)
        put("toIndex", toIndex)
    })

    fun next() = control(PartyOutgoing.NEXT, buildJsonObject { })

    fun previous() = control(PartyOutgoing.PREVIOUS, buildJsonObject { })

    fun kick(memberId: String) = control(PartyOutgoing.KICK, buildJsonObject {
        put("memberId", memberId)
    })

    fun setMaxMembers(count: Int) = control(PartyOutgoing.SET_MAX_MEMBERS, buildJsonObject {
        put("maxMembers", count)
    })

    fun setAutoplay(enabled: Boolean) = control(PartyOutgoing.SET_AUTOPLAY, buildJsonObject {
        put("enabled", enabled)
    })

    fun setHostOnlyControl(enabled: Boolean) = control(PartyOutgoing.SET_HOST_ONLY_CONTROL, buildJsonObject {
        put("enabled", enabled)
    })

    /** A control frame and its payload, built once. */
    private fun control(action: String, payload: JsonObject) = PartyOutgoing.Control(action, payload)
}

internal fun PartyTrack.toJson(): JsonObject = buildJsonObject {
    put("videoId", videoId)
    put("title", title)
    put("artist", artist)
    thumbnailUrl?.let { put("thumbnailUrl", it) }
    durationMs?.let { put("durationMs", it) }
    put("fromAutoplay", fromAutoplay)
}

/** Reading what the server sent. */
object PartyFrameCodec {

    private val json = Json {
        ignoreUnknownKeys = true
        // A server is free to add a field without breaking every client in the
        // field, and this client is not the only one talking to it.
        isLenient = true
        coerceInputValues = true
        classDiscriminator = "type"
    }

    /**
     * Decode one frame, or null when it is not one this client understands.
     *
     * Returns null rather than throwing, because a frame this build does not know
     * about is a normal event on a shared protocol and must not take the socket down
     * with it. A party that goes silent because the server said something new is a
     * far worse outcome than one that ignores it.
     */
    fun decode(text: String): PartyFrame? {
        val element = runCatching { json.parseToJsonElement(text) }.getOrNull() ?: return null
        val obj = element as? JsonObject ?: return null
        // `classDiscriminator` only kicks in for a sealed hierarchy, and the server
        // sends a flat object with a `type`, so the tag is read here and dispatched
        // by hand.
        val type = obj["type"]?.jsonPrimitive?.contentOrNull ?: return null
        return runCatching {
            when (type) {
                "welcome" -> json.decodeFromJsonElement(PartyFrame.Welcome.serializer(), obj)
                "state" -> json.decodeFromJsonElement(PartyFrame.State.serializer(), obj)
                "queue" -> json.decodeFromJsonElement(PartyFrame.Queue.serializer(), obj)
                "members" -> json.decodeFromJsonElement(PartyFrame.Members.serializer(), obj)
                "pong" -> json.decodeFromJsonElement(PartyFrame.Pong.serializer(), obj)
                "error" -> json.decodeFromJsonElement(PartyFrame.Failure.serializer(), obj)
                "bye" -> json.decodeFromJsonElement(PartyFrame.Bye.serializer(), obj)
                "activity" -> json.decodeFromJsonElement(PartyFrame.Activity.serializer(), obj)
                else -> null
            }
        }.getOrNull()
    }
}

package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * The socket's wire format.
 *
 * The outgoing tests are mostly about *field names*, because those are the one part
 * of a socket protocol that fails silently: a wrong name produces a frame the server
 * parses without complaint and ignores, and the symptom is a control button that
 * does nothing. The names here were read out of the Go server's own `applyControl`,
 * not inferred.
 */
class PartyProtocolTest {

    private fun encoded(frame: PartyOutgoing): JsonObject =
        kotlinx.serialization.json.Json.parseToJsonElement(PartyOutgoingCodec.encode(frame)).jsonObject

    // ---- What the client sends ---------------------------------------------

    @Test
    fun `a ping carries the local reading it will be given back`() {
        // A token, not a timestamp the server interprets: it comes back on the pong
        // and the two legs of the round trip are told apart by it.
        val frame = encoded(PartyOutgoing.Ping(clientMs = 12_345))
        assertEquals("ping", frame["type"]?.jsonPrimitive?.content)
        assertEquals(12_345L, frame["clientMs"]?.jsonPrimitive?.long)
    }

    @Test
    fun `sync asks for a state frame`() {
        assertEquals("sync", encoded(PartyOutgoing.Sync)["type"]?.jsonPrimitive?.content)
        assertEquals("syncQueue", encoded(PartyOutgoing.SyncQueue)["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun `a report carries this device's own playhead`() {
        val frame = encoded(PartyOutgoing.Report(positionMs = 4_200, isPlaying = true))
        assertEquals("report", frame["type"]?.jsonPrimitive?.content)
        assertEquals(4_200L, frame["positionMs"]?.jsonPrimitive?.long)
        assertEquals(true, frame["isPlaying"]?.jsonPrimitive?.boolean)
    }

    @Test
    fun `a control merges its payload onto the frame rather than nesting it`() {
        // The server reads its control fields off the frame itself
        // (`frame["positionMs"]`), not off a sub-object. Nesting would produce a
        // frame that parses and is silently ignored.
        val frame = encoded(PartyOutgoingCodec.seek(4_200))
        assertEquals("control", frame["type"]?.jsonPrimitive?.content)
        assertEquals("seek", frame["action"]?.jsonPrimitive?.content)
        assertEquals(4_200L, frame["positionMs"]?.jsonPrimitive?.long)
        assertNull(frame["payload"])
    }

    @Test
    fun `a single queued song goes in track and several in tracks`() {
        // The server reads `track` first, so putting one song in `tracks` is a
        // no-op that looks like it worked.
        val one = encoded(PartyOutgoingCodec.queueAdd(listOf(track("a"))))
        assertNotNull(one["track"])
        assertNull(one["tracks"])

        val many = encoded(PartyOutgoingCodec.queueAdd(listOf(track("a"), track("b"))))
        assertNotNull(many["tracks"])
        assertNull(many["track"])
        assertEquals(2, many["tracks"]?.jsonArray?.size)
    }

    @Test
    fun `a queue removal goes by video id and not by index`() {
        // Indices shift underneath you — somebody else queueing between your reading
        // the list and your sending the control removes the wrong song. An id cannot
        // shift.
        val frame = encoded(PartyOutgoingCodec.queueRemove("vid1"))
        assertEquals("vid1", frame["videoId"]?.jsonPrimitive?.content)
        assertNull(frame["index"])
    }

    @Test
    fun `the two enabled flags are not confused with each other`() {
        val autoplay = encoded(PartyOutgoingCodec.setAutoplay(true))
        assertEquals("setAutoplay", autoplay["action"]?.jsonPrimitive?.content)
        assertEquals(true, autoplay["enabled"]?.jsonPrimitive?.boolean)

        val hostOnly = encoded(PartyOutgoingCodec.setHostOnlyControl(true))
        assertEquals("setHostOnlyControl", hostOnly["action"]?.jsonPrimitive?.content)
        assertEquals(true, hostOnly["enabled"]?.jsonPrimitive?.boolean)
    }

    @Test
    fun `seek takes a position and the other controls take nothing`() {
        // `play` and `pause` carry no payload, and a frame with stray fields is one
        // more thing the server has to ignore.
        for (frame in listOf(PartyOutgoingCodec.play(), PartyOutgoingCodec.pause(), PartyOutgoingCodec.next())) {
            assertEquals(2, encoded(frame).size, "unexpected fields on $frame")
        }
    }

    @Test
    fun `a track on the wire carries the fields the server reads`() {
        val frame = encoded(PartyOutgoingCodec.setTrack(track("vid1", title = "T", artist = "A")))
        val sent = frame["track"]!!.jsonObject
        assertEquals("vid1", sent["videoId"]?.jsonPrimitive?.content)
        assertEquals("T", sent["title"]?.jsonPrimitive?.content)
        assertEquals("A", sent["artist"]?.jsonPrimitive?.content)
    }

    @Test
    fun `an absent optional field is left out rather than sent as null`() {
        // The server's struct tags are `omitempty`, so a null would be fine — but a
        // field that is absent is a field the server cannot be confused by.
        val sent = encoded(PartyOutgoingCodec.setTrack(track("vid1")))["track"]!!.jsonObject
        assertNull(sent["thumbnailUrl"])
        assertNull(sent["durationMs"])
    }

    // ---- What the client reads ---------------------------------------------

    @Test
    fun `a welcome frame is read`() {
        // Shaped from a real `POST /api/parties` response, not invented.
        val frame = PartyFrameCodec.decode(
            """
            {"type":"welcome","serverMs":1790395254965,
             "you":{"memberId":"29677a391fa3bc7b","userId":"u1","displayName":"Baguma",
                    "isHost":true,"connected":true,"joinedAtMs":1790395254965,"lastSeenMs":1790395254965},
             "party":{"code":"UVT2T1","maxMembers":5,"hostOnlyControl":false,
                      "members":[{"memberId":"29677a391fa3bc7b","displayName":"Baguma","isHost":true}],
                      "playback":{"seq":1,"isPlaying":false,"positionMs":0,"anchorMs":1790395254965},
                      "queue":{"seq":0,"index":-1,"items":[]}}}
            """.trimIndent(),
        )
        val welcome = assertIs<PartyFrame.Welcome>(frame)
        assertEquals("UVT2T1", welcome.party.code)
        assertTrue(welcome.you.isHost)
        assertEquals(1_790_395_254_965L, welcome.serverMs)
    }

    @Test
    fun `a state frame is read with its playback`() {
        val frame = PartyFrameCodec.decode(
            """
            {"type":"state","serverMs":1790395255000,
             "playback":{"seq":7,"track":{"videoId":"vid1","title":"T","artist":"A","durationMs":200000},
                         "queueSeq":3,"queueLength":5,"queueIndex":2,"isPlaying":true,
                         "positionMs":30000,"anchorMs":1790395254000,
                         "startedBy":"m1","startedByName":"Ada","autoplayEnabled":true}}
            """.trimIndent(),
        )
        val state = assertIs<PartyFrame.State>(frame)
        assertEquals(7L, state.playback.seq)
        assertEquals(3L, state.playback.queueSeq)
        assertEquals(2, state.playback.queueIndex)
        assertEquals(30_000L, state.playback.positionMs)
        assertEquals("Ada", state.playback.startedByName)
        assertEquals("vid1", state.playback.currentTrack?.videoId)
        assertEquals(200_000L, state.playback.currentTrack?.durationMs)
    }

    @Test
    fun `a pong is read and echoes the token`() {
        val pong = assertIs<PartyFrame.Pong>(PartyFrameCodec.decode("""{"type":"pong","clientMs":999,"serverMs":1000}"""))
        assertEquals(999L, pong.clientMs)
        assertEquals(1_000L, pong.serverMs)
    }

    @Test
    fun `a members frame is read with the party-wide setting`() {
        val frame = PartyFrameCodec.decode(
            """
            {"type":"members","serverMs":1000,"maxMembers":3,"hostOnlyControl":true,
             "members":[{"memberId":"m1","displayName":"Ada","isHost":true},
                        {"memberId":"m2","displayName":"Grace"}]}
            """.trimIndent(),
        )
        val members = assertIs<PartyFrame.Members>(frame)
        assertEquals(2, members.members.size)
        assertEquals(3, members.maxMembers)
        assertTrue(members.hostOnlyControl)
    }

    @Test
    fun `a bye is distinguished from an error`() {
        // The two mean opposite things to the client: a plain close is worth retrying
        // and this is a decision. Being kicked and being dropped are not the same
        // event, and treating them alike is a removed listener watching a reconnect
        // loop that is refused every time.
        assertEquals("kicked", assertIs<PartyFrame.Bye>(PartyFrameCodec.decode("""{"type":"bye","reason":"kicked"}""")).reason)
        assertEquals(
            "host_only",
            assertIs<PartyFrame.Failure>(PartyFrameCodec.decode("""{"type":"error","error":"host_only","message":"nope"}""")).error,
        )
    }

    @Test
    fun `an activity frame keeps the words the server wrote`() {
        val frame = PartyFrameCodec.decode(
            """{"type":"activity","action":"setTrack","by":"Ada","detail":"Changed the song to \"T\"","atMs":1234}""",
        )
        val activity = assertIs<PartyFrame.Activity>(frame)
        assertEquals("setTrack", activity.action)
        assertEquals("Ada", activity.by)
        assertEquals("""Changed the song to "T"""", activity.detail)
    }

    // ---- Refusals ----------------------------------------------------------

    @Test
    fun `a frame this build does not know is ignored rather than fatal`() {
        // A party that goes silent because the server said something new is a far
        // worse outcome than one that ignores it.
        assertNull(PartyFrameCodec.decode("""{"type":"somethingNew","x":1}"""))
    }

    @Test
    fun `nonsense is ignored rather than fatal`() {
        assertNull(PartyFrameCodec.decode("not json"))
        assertNull(PartyFrameCodec.decode("[]"))
        assertNull(PartyFrameCodec.decode("{}"))
        assertNull(PartyFrameCodec.decode(""))
    }

    @Test
    fun `an unknown field in a known frame is tolerated`() {
        // The server is free to add a field without breaking every client in the
        // field, and this client is not the only one talking to it.
        val frame = PartyFrameCodec.decode("""{"type":"pong","clientMs":1,"serverMs":2,"somethingNew":true}""")
        assertEquals(1L, assertIs<PartyFrame.Pong>(frame).clientMs)
    }

    @Test
    fun `a missing optional field does not fail the frame`() {
        // A heartbeat with no track is the normal case, not a malformed one.
        val frame = PartyFrameCodec.decode("""{"type":"state","serverMs":5,"playback":{"seq":2}}""")
        assertEquals(2L, assertIs<PartyFrame.State>(frame).playback.seq)
        assertNull(assertIs<PartyFrame.State>(frame).playback.track)
    }

    private fun track(
        videoId: String,
        title: String = "",
        artist: String = "",
    ) = PartyTrack(videoId = videoId, title = title, artist = artist)
}

package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The real server, run against the real decoder.
 *
 * Every other protocol test uses a fixture shaped by hand, and a hand-shaped fixture
 * only proves the fixture and the decoder agree. These two were captured verbatim off
 * a live `bitchord-jam` on the LAN — the bytes below are the server's, not mine —
 * so they prove the decoder agrees with the *server*.
 *
 * That distinction is the whole point. The two things most likely to be wrong in a
 * ported protocol are a field the client invented and a field the server stopped
 * sending, and neither shows up in a fixture written by the same person who wrote the
 * decoder.
 *
 * Regenerate with the socket at `http://<host>:8000/ws/parties/<CODE>`: the first two
 * frames the server sends, unedited.
 */
class PartyProtocolLiveTest {

    /** Verbatim from a live server. Note `seq: 0` — the first frame's sequence. */
    private val realWelcome = """
        {"party":{"code":"E63UED","createdAtMs":1790398562006,"hostOnlyControl":false,"maxMembers":5,
        "members":[{"avatarUrl":null,"connected":true,"displayName":"Host","isHost":true,
        "joinedAtMs":1790398562006,"lastSeenMs":1790398566425,"memberId":"dd983aba6f58ad44",
        "userId":"host"}],
        "playback":{"anchorMs":1790398562006,"autoplayEnabled":false,"effectivePositionMs":0,
        "isPlaying":false,"positionMs":0,"queueIndex":-1,"queueLength":0,"queueSeq":0,"seq":0,
        "startedBy":null,"startedByName":null,"track":null,"updatedAtMs":1790398562006,
        "updatedBy":null},
        "queue":{"index":-1,"items":[],"seq":0},"serverMs":1790398566425},
        "serverMs":1790398566425,"type":"welcome",
        "you":{"avatarUrl":null,"connected":true,"displayName":"Host","isHost":true,
        "joinedAtMs":1790398562006,"lastSeenMs":1790398566425,"memberId":"dd983aba6f58ad44",
        "userId":"host"}}
    """.trimIndent()

    /** Also verbatim, and the frame that follows the welcome on every connect. */
    private val realMembers = """
        {"hostOnlyControl":false,"maxMembers":5,
        "members":[{"avatarUrl":null,"connected":true,"displayName":"Host","isHost":true,
        "joinedAtMs":1790398562006,"lastSeenMs":1790398566425,"memberId":"dd983aba6f58ad44",
        "userId":"host"}],"serverMs":1790398566425,"type":"members"}
    """.trimIndent()

    @Test
    fun `the live welcome frame decodes`() {
        val welcome = assertIs<PartyFrame.Welcome>(PartyFrameCodec.decode(realWelcome))

        assertEquals("E63UED", welcome.party.code)
        assertEquals(5, welcome.party.maxMembers)
        assertEquals(1, welcome.party.members.size)
        assertTrue(welcome.party.members.first().isHost)
        assertTrue(welcome.party.members.first().connected)
        assertEquals("dd983aba6f58ad44", welcome.you.memberId)
        assertEquals(1_790_398_566_425L, welcome.serverMs)

        // The detail that matters: the server's *first* playback state carries
        // `seq: 0`, which is the same value as an uninitialised one. The session
        // records it on the welcome, so the next frame has to beat it — and if the
        // gate read a default instead, this party would never move again.
        assertEquals(0L, welcome.party.playback.seq)
        assertEquals(0L, welcome.party.playback.positionMs)
        assertNull(welcome.party.playback.track)
    }

    @Test
    fun `the live members frame decodes`() {
        val members = assertIs<PartyFrame.Members>(PartyFrameCodec.decode(realMembers))
        assertEquals(1, members.members.size)
        assertEquals(5, members.maxMembers)
        assertFalse(members.hostOnlyControl)
        assertEquals(1_790_398_566_425L, members.serverMs)
    }

    @Test
    fun `both live frames drive a real session`() {
        val session = PartySession()
        session.begin("http://192.168.0.252:8000", "E63UED")

        assertEquals(PartySession.Applied.Members, session.apply(PartyFrameCodec.decode(realWelcome)!!))
        assertEquals(PartySession.Applied.Members, session.apply(PartyFrameCodec.decode(realMembers)!!))

        val state = session.current
        assertTrue(state.inParty)
        assertTrue(state.isHost)
        assertEquals("Host", state.hostName)
        assertTrue(state.canControl)
        assertTrue(state.hasRoom)
        assertEquals(1_790_398_566_425L, state.lastServerMs)
    }

    @Test
    fun `a state frame after the live welcome is not swallowed`() {
        // The regression this whole file exists to catch. The welcome carries
        // `seq: 0`; if the session treated that as "nothing applied yet" the first
        // real state would be compared against a default 0 and dropped, and the party
        // would sit still while the socket stayed open and healthy.
        val session = PartySession()
        session.begin("http://192.168.0.252:8000", "E63UED")
        session.apply(PartyFrameCodec.decode(realWelcome)!!)

        val next = PartyFrame.State(
            playback = PartyPlayback(
                seq = 1,
                track = PartyTrack(videoId = "dQw4w9WgXcQ", title = "Verification", artist = "PartySync"),
                isPlaying = true,
                positionMs = 42_000,
                anchorMs = 1_790_398_566_425L,
            ),
            serverMs = 1_790_398_567_000L,
        )
        assertEquals(PartySession.Applied.Playback, session.apply(next))
        assertEquals("dQw4w9WgXcQ", session.current.playback.track?.videoId)
        assertTrue(session.current.playback.isPlaying)
    }

    @Test
    fun `the corrected position of a live frame advances with time`() {
        // Real numbers throughout: a real anchor from the server, and an offset
        // measured the way it is actually measured — a ping stamped on the way out
        // and a pong carrying the server's own reading.
        val clock = ServerClock()
        val frameServerMs = 1_790_398_566_425L
        clock.record(sentAtLocalMs = 0, serverMs = frameServerMs, receivedAtLocalMs = 40)

        val playback = assertIs<PartyFrame.Welcome>(
            PartyFrameCodec.decode(realWelcome),
        ).party.playback

        // The party's position was 0 as of its anchor, and the anchor is 4.419 s
        // before this frame was sent. A device 5 s later is therefore 9.419 s in, less
        // half the round trip: the offset is taken at the *midpoint* of the exchange,
        // so the 40 ms spent going and coming is 20 ms of error rather than 40.
        val halfRoundTrip = 20L
        val elapsed = frameServerMs - playback.anchorMs - halfRoundTrip
        assertEquals(5_000L + elapsed, clock.positionFor(playback.positionMs, playback.anchorMs, localNowMs = 5_000))

        // And 90 s later. Nothing re-reads the frame: the same `positionMs` with the
        // same anchor, corrected by the elapsed time, is the whole mechanism. That is
        // why a frame delayed by a slow network still lands in the right place instead
        // of a beat behind.
        assertEquals(
            90_000L + elapsed,
            clock.positionFor(playback.positionMs, playback.anchorMs, localNowMs = 90_000),
        )
    }

    @Test
    fun `an unsynced device holds rather than playing a stale position`() {
        // Before the first pong there is no offset and therefore no honest answer.
        val clock = ServerClock()
        assertEquals(0L, clock.positionFor(positionMs = 42_000, trueAtServerMs = 0, localNowMs = 5_000))
        assertNull(clock.serverNowMs(5_000))
    }

    @Test
    fun `the token is not something the frame carries`() {
        // Asserted as a property of the live frame rather than of the codec, because
        // it is a property of the *protocol*: the token travels in the handshake
        // header and must never appear in a frame, where it would land in every log
        // between here and there.
        assertNotNull(PartyFrameCodec.decode(realWelcome))
        assertTrue("token" !in realWelcome)
        assertTrue("Authorization" !in realWelcome)
    }

    private fun assertFalse(value: Boolean) = assertTrue(!value, "expected false")
}

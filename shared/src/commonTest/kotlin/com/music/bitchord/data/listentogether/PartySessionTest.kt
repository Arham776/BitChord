package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Turning frames into state.
 *
 * No socket, no server, no timing: every rule is exercised by handing the session a
 * frame. That is the reason the frame handling is separated from the transport, and
 * it is the only reason the rules below could be checked at all.
 */
class PartySessionTest {

    private fun session() = PartySession().apply { begin("https://jam.example", "ABC123") }

    private fun state(seq: Long, queueSeq: Long = 0, isPlaying: Boolean = true) =
        PartyFrame.State(
            playback = PartyPlayback(seq = seq, queueSeq = queueSeq, isPlaying = isPlaying),
            serverMs = 1_000 + seq,
        )

    private fun member(id: String, host: Boolean = false, name: String = "") =
        PartyMember(memberId = id, displayName = name, isHost = host, connected = true)

    // ---- The gate ----------------------------------------------------------

    @Test
    fun `a newer state is applied`() {
        val s = session()
        assertEquals(PartySession.Applied.Playback, s.apply(state(seq = 1)))
        assertEquals(1L, s.current.playback.seq)
    }

    @Test
    fun `an equal state is not applied`() {
        // The rule the whole sync rests on. The server re-sends the same state on
        // every heartbeat; an equal frame is not new information, and treating it as
        // one resets the playhead to a position captured when the frame was *first*
        // sent — a drift of one heartbeat per heartbeat.
        val s = session()
        s.apply(state(seq = 5))
        assertEquals(PartySession.Applied.Nothing, s.apply(state(seq = 5)))
    }

    @Test
    fun `an older state is not applied`() {
        // Two people hitting pause at the same moment must settle, not oscillate.
        val s = session()
        s.apply(state(seq = 9))
        assertEquals(PartySession.Applied.Nothing, s.apply(state(seq = 4)))
        assertEquals(9L, s.current.playback.seq)
    }

    @Test
    fun `a first state always applies`() {
        val s = session()
        assertEquals(PartySession.Applied.Playback, s.apply(state(seq = 0)))
    }

    // ---- The queue, and not too often --------------------------------------

    @Test
    fun `a stale queue asks to be refetched`() {
        val s = session()
        assertEquals(PartySession.Applied.Queue, s.apply(state(seq = 1, queueSeq = 7)))
        assertTrue(s.current.needsQueueRefetch)
    }

    @Test
    fun `a second stale frame before the refetch does not ask again`() {
        // Three people hitting next at once is exactly when a naive version refetches
        // three times.
        val s = session()
        s.apply(state(seq = 1, queueSeq = 7))
        s.queueRefetchSent()
        assertEquals(PartySession.Applied.Queue, s.apply(state(seq = 2, queueSeq = 7)))
        // Still stale, refetch already sent, so the next one must not ask again.
        assertEquals(PartySession.Applied.Playback, s.apply(state(seq = 3, queueSeq = 7)))
    }

    @Test
    fun `a queue frame clears the request`() {
        val s = session()
        s.apply(state(seq = 1, queueSeq = 7))
        s.apply(PartyFrame.Queue(PartyQueue(seq = 7, index = 0)))
        assertFalse(s.current.needsQueueRefetch)
    }

    @Test
    fun `a state whose queue is current does not ask for a refetch`() {
        val s = session()
        s.apply(PartyFrame.Queue(PartyQueue(seq = 7, index = 0)))
        assertEquals(PartySession.Applied.Playback, s.apply(state(seq = 1, queueSeq = 7)))
        assertFalse(s.current.needsQueueRefetch)
    }

    @Test
    fun `a welcome means the held queue is current`() {
        // It carries a full snapshot, so a first state frame must not trigger a
        // redundant refetch.
        val s = session()
        s.apply(PartyFrame.Welcome(
            you = member("m1", host = true),
            party = PartySnapshot(code = "ABC123", queue = PartyQueue(seq = 4)),
        ))
        assertEquals(PartySession.Applied.Playback, s.apply(state(seq = 1, queueSeq = 4)))
    }

    // ---- Membership --------------------------------------------------------

    @Test
    fun `members arrive in their own frame`() {
        // Membership changes on its own schedule — somebody's phone locking is not a
        // playback event — and folding it into the heartbeat would put a list of
        // people on every device's metered connection every few seconds.
        val s = session()
        s.apply(PartyFrame.Members(listOf(member("m1", host = true), member("m2")), maxMembers = 3))
        assertEquals(2, s.current.members.size)
        assertEquals(3, s.current.maxMembers)
        assertEquals("m1", s.current.host?.memberId)
    }

    @Test
    fun `the host only setting comes from the server`() {
        // A device that disagrees with the server about this is a device whose
        // controls appear to work and do nothing.
        val s = session()
        s.apply(PartyFrame.Welcome(member("m1"), PartySnapshot(hostOnlyControl = true)))
        assertFalse(s.current.canControl)

        s.apply(PartyFrame.Welcome(member("m1", host = true), PartySnapshot(hostOnlyControl = true)))
        assertTrue(s.current.canControl)
    }

    @Test
    fun `room is counted over members and not over connected members`() {
        // Somebody whose socket dropped is still holding their slot, and letting a
        // sixth person in would push somebody out of a party they never left.
        val s = session()
        val dropped = PartyMember(memberId = "m2", connected = false)
        s.apply(PartyFrame.Members(listOf(member("m1"), member("m2"), member("m3"), dropped, member("m5")), maxMembers = 5))
        assertTrue(s.current.isFull)
        assertFalse(s.current.hasRoom)
    }

    // ---- Leaving -----------------------------------------------------------

    @Test
    fun `a bye ends the session and keeps the reason`() {
        // A decision, not a disconnection — so the screen can say what happened
        // instead of showing a generic failure.
        val s = session()
        assertEquals(PartySession.Applied.Left, s.apply(PartyFrame.Bye(reason = "kicked")))
        assertFalse(s.current.inParty)
        assertEquals("left", s.current.error?.code)
        assertEquals("kicked", s.current.error?.message)
    }

    @Test
    fun `a refusal is recorded without ending the session`() {
        val s = session()
        s.apply(PartyFrame.Failure(error = "host_only", message = "Only the host can do that."))
        assertTrue(s.current.inParty)
        assertEquals("host_only", s.current.error?.code)
    }

    @Test
    fun `a later good frame clears a refusal`() {
        val s = session()
        s.apply(PartyFrame.Failure("host_only", "no"))
        s.apply(PartyFrame.State(PartyPlayback(seq = 1)))
        assertNull(s.current.error)
    }

    @Test
    fun `an activity frame is kept for display and does not disturb the rest`() {
        val s = session()
        s.apply(state(seq = 3))
        s.apply(PartyFrame.Activity(action = "setTrack", by = "Ada", detail = "Changed the song", atMs = 500))
        assertEquals(3L, s.current.playback.seq)
        assertEquals("Ada", s.current.activity?.by)
    }

    @Test
    fun `a pong records the server clock without touching playback`() {
        val s = session()
        s.apply(state(seq = 3, isPlaying = true))
        s.apply(PartyFrame.Pong(clientMs = 1, serverMs = 9_999))
        assertEquals(9_999L, s.current.lastServerMs)
        assertTrue(s.current.playback.isPlaying)
    }

    // ---- Starting and stopping --------------------------------------------

    @Test
    fun `beginning a session starts empty and in the party`() {
        val s = PartySession()
        assertFalse(s.current.inParty)
        s.begin("https://jam.example", "ABC123")
        assertTrue(s.current.inParty)
        assertEquals("ABC123", s.code)
        assertEquals("https://jam.example", s.serverBase)
    }

    @Test
    fun `resetting clears everything including the bound server`() {
        val s = session()
        s.apply(state(seq = 3))
        s.reset()
        assertFalse(s.current.inParty)
        assertEquals(0L, s.current.playback.seq)
        assertEquals("", s.serverBase)
    }

    @Test
    fun `the bound server has no public setter`() {
        // Idle health checks must never be able to move a live session to a different
        // server, and the reason they cannot is that there is nothing to call:
        // `begin` sets it and `reset` clears it, and nothing in between writes it.
        val s = session()
        assertEquals("https://jam.example", s.serverBase)
        s.apply(state(seq = 1))
        s.apply(PartyFrame.Members(listOf(member("m1", host = true))))
        assertEquals("https://jam.example", s.serverBase)
        s.reset()
        assertEquals("", s.serverBase)
    }

    @Test
    fun `a new party rebinds the server`() {
        // Leaving and joining somewhere else is legitimate; what must not happen is
        // the server moving *under* a live session.
        val s = session()
        s.reset()
        s.begin("https://other.example", "XYZ789")
        assertEquals("https://other.example", s.serverBase)
        assertEquals("XYZ789", s.code)
    }

    // ---- Names -------------------------------------------------------------

    @Test
    fun `a member with no name falls back to a shortened id`() {
        // A nameless member renders as a blank row, and a blank row in a list of
        // people reads as a bug rather than as somebody who has not set a name.
        assertEquals("ABC123", PartyMember(memberId = "abc123def456").name)
    }

    @Test
    fun `a member with a name uses it`() {
        assertEquals("Ada", PartyMember(memberId = "abc123", displayName = "Ada").name)
    }
}

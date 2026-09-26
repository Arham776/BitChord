package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The parts of [PartyState] a screen is built out of: who am I, may I drive the music,
 * and is the connection up.
 *
 * Separate from `PartySessionTest` because these are answers about a *value* rather
 * than about a frame. They are the properties the Listen Together view reads on every
 * redraw, so a change to one of them is a change to what the screen says — which is
 * why they are pinned here rather than left to be discovered in the interface.
 */
class PartyStateTest {

    private fun member(id: String, host: Boolean = false) =
        PartyMember(memberId = id, displayName = "M$id", isHost = host, connected = true)

    private fun state(
        inParty: Boolean = true,
        you: PartyMember? = member("me"),
        members: List<PartyMember> = listOf(member("me"), member("them")),
        maxMembers: Int = 5,
        hostOnlyControl: Boolean = false,
    ) = PartyState(
        inParty = inParty,
        you = you,
        members = members,
        maxMembers = maxMembers,
        hostOnlyControl = hostOnlyControl,
    )

    // ---- Who am I -----------------------------------------------------------

    @Test
    fun `my member id is what a member list is compared against`() {
        assertEquals("abc12345", state(you = member("abc12345")).myMemberId)
    }

    @Test
    fun `my member id is empty before the first frame`() {
        // Compared against rather than null-checked, so an empty id can never match a
        // member's — a list rendered before the welcome would otherwise mark whichever
        // row happened to have a blank id.
        assertEquals("", state(you = null).myMemberId)
    }

    @Test
    fun `a member list can say which row is me`() {
        val s = state(you = member("me"))
        assertTrue(s.isMe(member("me")))
        assertFalse(s.isMe(member("them")))
    }

    @Test
    fun `no member is me before the first frame`() {
        assertFalse(state(you = null).isMe(member("anyone")))
    }

    // ---- May I drive the music ---------------------------------------------

    @Test
    fun `an unlocked party lets anybody drive the music`() {
        assertTrue(state(hostOnlyControl = false).canControl)
    }

    @Test
    fun `a locked party locks a listener out`() {
        val s = state(you = member("me"), hostOnlyControl = true)
        assertFalse(s.canControl)
        assertTrue(s.controlsLocked)
    }

    @Test
    fun `a locked party never locks the host out of their own`() {
        // The server does not apply the rule to the host either, so a client that did
        // would disable controls the server would have honoured.
        val s = state(you = member("me", host = true), hostOnlyControl = true)
        assertTrue(s.canControl)
        assertFalse(s.controlsLocked)
    }

    @Test
    fun `nobody is locked out of a party that is not a party`() {
        // A device with no party has no business showing a lock, and a lock on the
        // screen would read as "the host has taken control" about nobody.
        val s = state(inParty = false, you = null, members = emptyList(), hostOnlyControl = true)
        assertFalse(s.controlsLocked)
    }

    // ---- The connection -----------------------------------------------------

    @Test
    fun `a device with no party is offline`() {
        assertEquals(PartyConnection.OFFLINE, PartyState().connection)
    }

    @Test
    fun `joining starts as connecting rather than live`() {
        // A screen that said "live" the instant a code was accepted would be
        // announcing a party that has not confirmed it exists.
        val s = PartySession()
        s.begin("https://jam.example", "ABC123")
        assertEquals(PartyConnection.CONNECTING, s.current.connection)
        assertTrue(s.current.inParty)
    }

    @Test
    fun `the first frame is what makes it live`() {
        val s = PartySession()
        s.begin("https://jam.example", "ABC123")
        s.apply(
            PartyFrame.Welcome(
                you = member("me", host = true),
                party = PartySnapshot(code = "ABC123", members = listOf(member("me", host = true))),
                serverMs = 1_000,
            ),
        )
        assertEquals(PartyConnection.LIVE, s.current.connection)
    }

    @Test
    fun `being removed takes the connection down with the party`() {
        val s = PartySession()
        s.begin("https://jam.example", "ABC123")
        s.apply(PartyFrame.Bye(reason = "kicked", serverMs = 1_000))
        assertEquals(PartyConnection.OFFLINE, s.current.connection)
        assertFalse(s.current.inParty)
    }

    @Test
    fun `resetting forgets the clock as well as the party`() {
        // A stale offset outliving the party would be applied to the next one's
        // positions, and the next party is on a server with a different clock.
        val s = PartySession()
        s.recordPong(sentAtLocalMs = 1_000, serverMs = 500_000, receivedAtLocalMs = 1_200)
        assertTrue(s.current.clockSynced)
        s.reset()
        assertFalse(s.current.clockSynced)
        assertEquals(0L, s.current.roundTripMs)
        assertNull(s.serverClock().offsetMs)
    }

    @Test
    fun `a pong publishes the measurement rather than leaving it in the clock`() {
        // "In sync with the party" is the first thing the screen says, and a value
        // only reachable through a collaborator is not something a view can observe.
        val s = PartySession()
        assertFalse(s.current.clockSynced)
        s.recordPong(sentAtLocalMs = 1_000, serverMs = 500_000, receivedAtLocalMs = 1_200)
        assertTrue(s.current.clockSynced)
        assertEquals(200L, s.current.roundTripMs)
    }

    // ---- Room ---------------------------------------------------------------

    @Test
    fun `room is counted over members and not over connected ones`() {
        val s = state(
            members = listOf(member("me"), member("disconnected")),
            maxMembers = 2,
        )
        assertTrue(s.isFull)
        assertTrue(s.isFullFor(joining = true))
    }

    @Test
    fun `a full party reads as full to nobody who is already in it`() {
        // The answer to "is there room" is about a device that is not here yet, and
        // asking it about the party you are standing in gives a confusing "no".
        assertFalse(state(maxMembers = 2).isFullFor(joining = false))
    }

    @Test
    fun `the host is found among the members`() {
        val s = state(you = member("me"), members = listOf(member("me"), member("host", host = true)))
        assertEquals("Mhost", s.hostName)
    }

    @Test
    fun `the host name is empty rather than guessed when the host is not resolvable`() {
        assertEquals("", state(you = null, members = emptyList()).hostName)
    }
}

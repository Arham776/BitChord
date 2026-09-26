package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Choosing which server to talk to.
 *
 * Almost every test here is about a probe failing, which is why [resolve] takes the
 * probes as parameters: the interesting cases are the ones that need a server to be
 * down, and a test that has to take a server down to run is a test that does not
 * get run.
 */
class ServerSelectionTest {

    private val builtIn = "https://built.in"
    private val custom = "https://mine.example"

    /** Probe outcomes by address. Anything not named is reported offline. */
    private fun probes(vararg online: String): (String, Long) -> ProbeResult = { base, _ ->
        if (base in online) ProbeResult(isOnline = true, latencyMs = 40) else ProbeResult(isOnline = false)
    }

    private fun connectionOf(choice: ServerChoice) = choice.connection

    // ---- Nothing configured ------------------------------------------------

    @Test
    fun `with no server at all nothing is probed`() {
        // The shipped default is empty, so this is what a fresh install is in. It has
        // to be its own state: reported as Offline it would claim a connection
        // failed, when nothing was ever attempted.
        var probes = 0
        val choice = runBlockingProbe(customServer = "", defaultServer = "") { _, _ ->
            probes++
            ProbeResult(false)
        }
        assertIs<ServerConnection.Unconfigured>(choice.connection)
        assertEquals("", choice.base)
        assertEquals(0, probes)
    }

    @Test
    fun `an unconfigured state reports no health and no latency`() {
        val conn = ServerConnection.Unconfigured
        assertEquals(ServerHealth.UNKNOWN, conn.health)
        assertNull(conn.latencyMs)
        assertFalse(conn.isFallback)
    }

    // ---- The built-in server -----------------------------------------------

    @Test
    fun `the built-in server is used when it answers`() {
        val choice = runBlockingProbe(customServer = "", defaultServer = builtIn) { base, _ ->
            ProbeResult(base == builtIn, 40)
        }
        assertIs<ServerConnection.DefaultOnline>(choice.connection)
        assertEquals(builtIn, choice.base)
        assertEquals(40, choice.connection.latencyMs)
        assertFalse(choice.connection.isFallback)
    }

    @Test
    fun `the built-in server being down is offline rather than unconfigured`() {
        // The distinction that matters: this one *was* tried.
        val choice = runBlockingProbe(customServer = "", defaultServer = builtIn) { _, _ -> ProbeResult(false) }
        assertIs<ServerConnection.Offline>(choice.connection)
        assertEquals(builtIn, choice.base)
    }

    // ---- A configured server ----------------------------------------------

    @Test
    fun `a configured server that answers is used`() {
        val choice = runBlockingProbe(customServer = custom, defaultServer = builtIn) { base, _ ->
            ProbeResult(base == custom, 25)
        }
        assertIs<ServerConnection.CustomOnline>(choice.connection)
        assertEquals(custom, choice.base)
        assertEquals(25, choice.connection.latencyMs)
        assertFalse(choice.connection.isFallback)
    }

    @Test
    fun `a configured server equal to the built-in one is not a configured server`() {
        // Otherwise typing the built-in address into the box probes it twice per
        // refresh and reports a fallback that is not one.
        var probes = 0
        val choice = runBlockingProbe(customServer = "$builtIn/", defaultServer = builtIn) { base, _ ->
            probes++
            ProbeResult(base == builtIn, 40)
        }
        assertIs<ServerConnection.DefaultOnline>(choice.connection)
        assertEquals(1, probes)
    }

    @Test
    fun `a configured server that differs only in spelling is not a second server`() {
        var probes = 0
        val choice = runBlockingProbe(customServer = "MINE.example".let { "https://$it" }, defaultServer = builtIn) { _, _ ->
            probes++
            ProbeResult(true, 40)
        }
        assertIs<ServerConnection.CustomOnline>(choice.connection)
        assertEquals(1, probes)
    }

    // ---- Falling back ------------------------------------------------------

    @Test
    fun `a configured server that is down falls back to the built-in one`() {
        val choice = runBlockingProbe(customServer = custom, defaultServer = builtIn) { base, _ ->
            ProbeResult(base == builtIn, 55)
        }
        assertIs<ServerConnection.CustomFallback>(choice.connection)
        assertEquals(builtIn, choice.base)
        assertTrue(choice.connection.isFallback)
    }

    @Test
    fun `a fallback reports the latency of the server actually in use`() {
        // The subtlety: the address the user is about to be on is the one whose time
        // this is. Reporting the failed probe's time would put a number on screen
        // describing a connection that does not exist.
        val choice = runBlockingProbe(customServer = custom, defaultServer = builtIn) { base, _ ->
            if (base == custom) ProbeResult(isOnline = false, latencyMs = 8_000) else ProbeResult(true, 55)
        }
        val conn = connectionOf(choice)
        assertIs<ServerConnection.CustomFallback>(conn)
        assertEquals(55, conn.latencyMs)
    }

    @Test
    fun `both servers down is offline`() {
        val choice = runBlockingProbe(customServer = custom, defaultServer = builtIn) { _, _ -> ProbeResult(false) }
        assertIs<ServerConnection.Offline>(choice.connection)
        // Which address is reported, when neither works, does not matter to the
        // caller — but it must be one of the two, never a third.
        assertTrue(choice.base == custom || choice.base == builtIn)
    }

    @Test
    fun `a configured server with nothing to fall back to is offline not fallback`() {
        // There is no second address to have fallen back *from*, so calling it a
        // fallback would be a claim about something that did not happen.
        val choice = runBlockingProbe(customServer = custom, defaultServer = "") { _, _ -> ProbeResult(false) }
        assertIs<ServerConnection.Offline>(choice.connection)
        assertEquals(custom, choice.base)
        assertFalse(choice.connection.isFallback)
    }

    // ---- A malformed address is absent, not fatal -------------------------

    @Test
    fun `an address that does not parse is treated as no address`() {
        // A typo in the box should cost the listener their own server for the
        // session, not the feature.
        val choice = runBlockingProbe(customServer = "http://", defaultServer = builtIn) { base, _ ->
            ProbeResult(base == builtIn, 40)
        }
        assertIs<ServerConnection.DefaultOnline>(choice.connection)
        assertEquals(builtIn, choice.base)
    }

    @Test
    fun `a malformed address is normalised away before being compared`() {
        val choice = runBlockingProbe(customServer = "  BUILT.IN/  ", defaultServer = builtIn) { _, _ ->
            ProbeResult(true, 40)
        }
        assertIs<ServerConnection.DefaultOnline>(choice.connection)
    }

    // ---- Health, folded out of the connection state ------------------------

    @Test
    fun `health is folded out of the connection state`() {
        assertEquals(ServerHealth.ONLINE, ServerConnection.DefaultOnline(1).health)
        assertEquals(ServerHealth.ONLINE, ServerConnection.CustomOnline(1).health)
        assertEquals(ServerHealth.ONLINE, ServerConnection.CustomFallback(1).health)
        assertEquals(ServerHealth.OFFLINE, ServerConnection.Offline.health)
        assertEquals(ServerHealth.CHECKING, ServerConnection.Checking.health)
    }

    @Test
    fun `a state with no latency says so rather than reporting zero`() {
        // Zero is a real answer here — the built-in server answered instantly — so it
        // cannot double as "not measured".
        assertNull(ServerConnection.Offline.latencyMs)
        assertNull(ServerConnection.Checking.latencyMs)
        assertNull(ServerConnection.Unconfigured.latencyMs)
        assertEquals(0, ServerConnection.CustomOnline(0).latencyMs)
    }

    // ---- Which server a switch should use ----------------------------------

    @Test
    fun `an invite that names a server wins over everything`() {
        val invite = "https://invite.example"
        assertEquals(invite, ServerSelection.switchTarget(invite, custom, builtIn))
    }

    @Test
    fun `an invite's server is normalised before it is used`() {
        assertEquals(
            "https://invite.example",
            ServerSelection.switchTarget("INVITE.example/", custom, builtIn),
        )
    }

    @Test
    fun `a switch with no explicit target lands on the resolved idle server`() {
        // The load-bearing case: a typed code, entered while already live in a party,
        // has to reach whichever server idle operations resolve to. Handed "" instead
        // it is a malformed target and the switch is refused outright.
        assertEquals(builtIn, ServerSelection.switchTarget(null, "", builtIn))
        assertEquals(custom, ServerSelection.switchTarget(null, custom, builtIn))
    }

    @Test
    fun `an invite naming an unusable server falls through rather than failing`() {
        val choice = ServerSelection.switchTarget("ftp://nope", "", builtIn)
        assertEquals(builtIn, choice)
    }

    // ---- Whether another server is worth trying ----------------------------

    @Test
    fun `a transport failure is eligible because a different server might answer`() {
        assertTrue(PartyFailure.Transport("connection refused").isEligibleForFallback())
    }

    @Test
    fun `a 5xx is eligible because the server is unwell rather than absent`() {
        assertTrue(PartyFailure.Server(500).isEligibleForFallback())
        assertTrue(PartyFailure.Server(503).isEligibleForFallback())
    }

    @Test
    fun `a 4xx is not eligible because the server is working and said no`() {
        // The sharp edge. A 403 on a full party is not a reason to try the built-in
        // server: the party is full, full will be the answer there too, and a code
        // that exists on one server can exist on another as a *different party*.
        assertFalse(PartyFailure.Rejected(403).isEligibleForFallback())
        assertFalse(PartyFailure.Rejected(404).isEligibleForFallback())
        assertFalse(PartyFailure.Rejected(401).isEligibleForFallback())
        assertFalse(PartyFailure.Rejected(429).isEligibleForFallback())
    }

    @Test
    fun `a 5xx boundary is exact`() {
        // 499 is the server working; 500 is not. And a 2xx never arrives here.
        assertFalse(PartyFailure.Server(499).isEligibleForFallback())
        assertTrue(PartyFailure.Server(500).isEligibleForFallback())
    }

    @Test
    fun `anything else is not eligible`() {
        // A parse failure or a bug is not the server's condition, and retrying it
        // somewhere else produces the same bug somewhere else.
        assertFalse(PartyFailure.Other("malformed json").isEligibleForFallback())
    }

    // ---- A tiny runner, so each test reads as one call --------------------

    private fun runBlockingProbe(
        customServer: String,
        defaultServer: String = builtIn,
        probe: (String, Long) -> ProbeResult,
    ): ServerChoice = kotlinx.coroutines.runBlocking {
        ServerSelection.resolve(customServer, defaultServer) { base, timeout -> probe(base, timeout) }
    }

    @Test
    fun `each server is given its own timeout`() {
        // A listener's own server gets a shorter patience than the built-in one: it is
        // usually on a LAN or a home connection, and waiting it out delays the
        // screen for no gain.
        val timeouts = mutableListOf<Long>()
        runBlockingProbe(customServer = custom) { base, timeout ->
            timeouts += timeout
            ProbeResult(base == custom, 10)
        }
        assertEquals(listOf(ServerSelection.CUSTOM_SERVER_TIMEOUT_MS), timeouts)

        timeouts.clear()
        runBlockingProbe(customServer = "") { _, timeout ->
            timeouts += timeout
            ProbeResult(true, 10)
        }
        assertEquals(listOf(ServerSelection.DEFAULT_SERVER_TIMEOUT_MS), timeouts)
    }
}

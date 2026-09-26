package com.music.bitchord.data.listentogether

import com.music.bitchord.data.settings.InstallId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Who this install is, to a party server.
 *
 * The device id is the sharp end of this. The server's `backend/party.Join` matches a
 * returning member on `DeviceId` alone, so a constant there is not a cosmetic
 * limitation: it is the second Mac refused a place in a party the first Mac is
 * standing in. These tests exist so that cannot come back quietly.
 *
 * Nothing here goes through [InstallId.get]. That reaches the real `NSUserDefaults`,
 * and a test that wrote there would leave an id behind for every other test in the
 * build — and, worse, on the machine that ran them.
 */
class PartyIdentityTest {

    // ---- The device id, which is the whole point ---------------------------

    @Test
    fun `two installs are two devices`() {
        val one = PartyIdentityFactory.resolve(deviceId = InstallId.mint(), nickname = "Sam")
        val two = PartyIdentityFactory.resolve(deviceId = InstallId.mint(), nickname = "Sam")
        assertNotEquals(one.deviceId, two.deviceId)
    }

    @Test
    fun `a stored device id is reused rather than a new one being minted`() {
        val stored = mutableListOf<String>()
        val id = InstallId.reuseOrMint(
            stored = "already-here",
            mint = { "freshly-made" },
            persist = { stored += it },
        )
        assertEquals("already-here", id)
        assertTrue(stored.isEmpty(), "a stored id must not be written back")
    }

    @Test
    fun `a blank stored id is replaced and the replacement is written out`() {
        val stored = mutableListOf<String>()
        val id = InstallId.reuseOrMint(stored = "   ", mint = { "freshly-made" }, persist = { stored += it })
        assertEquals("freshly-made", id)
        assertEquals(listOf("freshly-made"), stored)
    }

    @Test
    fun `a missing stored id is minted once and written out`() {
        val stored = mutableListOf<String>()
        val id = InstallId.reuseOrMint(stored = null, mint = { "freshly-made" }, persist = { stored += it })
        assertEquals("freshly-made", id)
        assertEquals(listOf("freshly-made"), stored)
    }

    @Test
    fun `a minted device id is a version 4 uuid`() {
        // The shape, because a party server's logs are read by people, and a value
        // that is merely 32 hex characters is not recognisable as an identifier.
        val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        repeat(40) { assertTrue(uuid.matches(InstallId.mint()), "not a version 4 UUID") }
    }

    @Test
    fun `two mints do not collide`() {
        val ids = List(200) { InstallId.mint() }
        assertEquals(ids.size, ids.toSet().size, "a mint that repeats would collide two installs")
    }

    // ---- The person ---------------------------------------------------------

    @Test
    fun `the same account on two devices is the same person`() {
        val phone = PartyIdentityFactory.resolve(deviceId = InstallId.mint(), nickname = "", accountEmail = "sam@example.com")
        val laptop = PartyIdentityFactory.resolve(deviceId = InstallId.mint(), nickname = "", accountEmail = "sam@example.com")
        assertEquals(phone.userId, laptop.userId)
        assertNotEquals(phone.deviceId, laptop.deviceId)
    }

    @Test
    fun `the account email is not what reaches the server`() {
        val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "", accountEmail = "sam@example.com")
        assertFalse(identity.userId.contains("sam"), "the raw account leaked: ${identity.userId}")
        assertFalse(identity.userId.contains("example"), "the raw account leaked: ${identity.userId}")
    }

    @Test
    fun `the case of an account does not change who it is`() {
        val lower = PartyIdentityFactory.resolve(deviceId = "d", nickname = "", accountEmail = "Sam@Example.com")
        val upper = PartyIdentityFactory.resolve(deviceId = "d", nickname = "", accountEmail = "sam@example.com")
        assertEquals(lower.userId, upper.userId)
    }

    @Test
    fun `an absent account still gets a person id rather than a blank one`() {
        val identity = PartyIdentityFactory.resolve(deviceId = "install-1", nickname = "Sam")
        assertTrue(identity.userId.isNotBlank())
    }

    @Test
    fun `a signed out install is still stable to itself`() {
        val first = PartyIdentityFactory.resolve(deviceId = "install-1", nickname = "Sam")
        val again = PartyIdentityFactory.resolve(deviceId = "install-1", nickname = "Sam")
        assertEquals(first.userId, again.userId)
    }

    @Test
    fun `two accounts do not collide when the parts are split differently`() {
        // Without a separator in the hashed string, "ab" + "c" and "a" + "bc" would
        // digest the same input and be the same person.
        val one = PartyIdentityFactory.userIdOf(accountEmail = null, accountName = "ab", deviceId = "c")
        val two = PartyIdentityFactory.userIdOf(accountEmail = null, accountName = "a", deviceId = "bc")
        assertNotEquals(one, two)
    }

    @Test
    fun `a signed out user id is the install's and not a constant`() {
        val one = PartyIdentityFactory.userIdOf(null, null, "install-1")
        val two = PartyIdentityFactory.userIdOf(null, null, "install-2")
        assertNotEquals(one, two)
    }

    @Test
    fun `the person id is the length upstream sends`() {
        // The two clients are meant to be indistinguishable to the server; a longer
        // id here would be the one place the port is visibly its own thing.
        assertEquals(32, PartyIdentityFactory.resolve(deviceId = "d", nickname = "Sam").userId.length)
    }

    // ---- The name -----------------------------------------------------------

    @Test
    fun `a chosen nickname is the name used`() {
        val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "  Sam  ", accountName = "Sam Smith")
        assertEquals("Sam", identity.displayName)
    }

    @Test
    fun `without a nickname the account name is used`() {
        val identity = PartyIdentityFactory.resolve(
            deviceId = "d", nickname = "   ", accountName = "Sam Smith", accountEmail = "sam@example.com",
        )
        assertEquals("Sam Smith", identity.displayName)
    }

    @Test
    fun `without either the part of the email before the at sign is used`() {
        val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "", accountEmail = "sam@example.com")
        assertEquals("sam", identity.displayName)
    }

    @Test
    fun `with nothing at all there is still a name to show`() {
        // A member row with a blank name is a row a host cannot tell from a second
        // one of themselves.
        val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "")
        assertEquals(PartyIdentityFactory.FALLBACK_NAME, identity.displayName)
    }

    @Test
    fun `a name is bounded because every other device renders it`() {
        val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "x".repeat(500))
        assertEquals(PartyIdentityFactory.MAX_NAME_LENGTH, identity.displayName.length)
    }

    // ---- The face -----------------------------------------------------------

    @Test
    fun `an https avatar is carried`() {
        val identity = PartyIdentityFactory.resolve(
            deviceId = "d", nickname = "Sam", accountAvatarUrl = "https://example.com/a.jpg",
        )
        assertEquals("https://example.com/a.jpg", identity.avatarUrl)
    }

    @Test
    fun `an avatar that is not a web address is refused`() {
        // The server's `JoinRequest.Validate` refuses anything not prefixed http:// or
        // https://, so a value accepted here but not there is a *refused join* rather
        // than a missing avatar. "httpx://" is the case a loose prefix check lets
        // through.
        listOf("file:///etc/passwd", "data:image/png;base64;AAAA", "javascript:alert(1)", "httpx://evil.test/a.png")
            .forEach { candidate ->
                val identity = PartyIdentityFactory.resolve(deviceId = "d", nickname = "Sam", accountAvatarUrl = candidate)
                assertNull(identity.avatarUrl, "accepted $candidate")
            }
    }
}

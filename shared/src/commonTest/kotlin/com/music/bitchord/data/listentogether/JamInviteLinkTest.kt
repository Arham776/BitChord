package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Reading party invites.
 *
 * This parses a string that arrived from outside the app into a code that will be
 * sent to a server, so the tests are mostly about what is *refused*. A permissive
 * parser here does not fail visibly: it produces a code that does not exist, and
 * the symptom is "invite links do not work" on somebody else's device.
 */
class JamInviteLinkTest {

    private fun code() = "ABC123"

    // ---- The custom scheme -------------------------------------------------

    @Test
    fun `a custom-scheme link in the path is read`() {
        assertEquals(code(), JamInviteLink.parseInvite("bitchord://party/ABC123")?.code)
    }

    @Test
    fun `a custom-scheme link in the query is read`() {
        assertEquals(code(), JamInviteLink.parseInvite("bitchord://party?code=ABC123")?.code)
    }

    @Test
    fun `a lowercase code is accepted and upper-cased`() {
        // A code arrives in whatever case the sharer had it in; the server is
        // case-sensitive and the person tapping did nothing wrong.
        assertEquals(code(), JamInviteLink.parseInvite("bitchord://party/abc123")?.code)
    }

    @Test
    fun `a trailing slash is tolerated`() {
        assertEquals(code(), JamInviteLink.parseInvite("bitchord://party/ABC123/")?.code)
    }

    @Test
    fun `a code with a stray character is cleaned rather than refused`() {
        assertEquals("ABC123", JamInviteLink.cleanCode("ABC-123"))
        assertEquals("ABC123", JamInviteLink.cleanCode(" ABC123 "))
    }

    // ---- The web domain ---------------------------------------------------

    @Test
    fun `a web invite is read`() {
        assertEquals(code(), JamInviteLink.parseInvite("https://bitchord.kushagrasingh.in/invite/ABC123")?.code)
    }

    @Test
    fun `a web invite with a trailing slash is read`() {
        assertEquals(
            code(),
            JamInviteLink.parseInvite("https://bitchord.kushagrasingh.in/invite/ABC123/")?.code,
        )
    }

    @Test
    fun `a web invite with other content around it is not`() {
        // The path is matched whole, so a link with something appended cannot
        // quietly parse as a code.
        assertNull(JamInviteLink.parseInvite("https://bitchord.kushagrasingh.in/invite/ABC123/more"))
    }

    // ---- Refusals ---------------------------------------------------------

    @Test
    fun `a code of the wrong length is not a code`() {
        // Length is checked against what a code actually looks like, which is the
        // half that stops a whole sentence being accepted and then failing
        // silently against the server.
        assertNull(JamInviteLink.cleanCode("ABC12"))
        assertNull(JamInviteLink.cleanCode("ABC1234"))
        assertNull(JamInviteLink.cleanCode(""))
    }

    @Test
    fun `another app's link is not an invite`() {
        assertNull(JamInviteLink.parseInvite("spotify:track:abc"))
        assertNull(JamInviteLink.parseInvite("https://example.invalid/invite/ABC123"))
    }

    @Test
    fun `nothing is not an invite`() {
        assertNull(JamInviteLink.parseInvite(null))
        assertNull(JamInviteLink.parseInvite(""))
        assertNull(JamInviteLink.parseInvite("   "))
        assertNull(JamInviteLink.parseInvite("not a url at all"))
    }

    @Test
    fun `the custom scheme with the wrong host is not an invite`() {
        assertNull(JamInviteLink.parseInvite("bitchord://somethingelse/ABC123"))
    }

    @Test
    fun `plain http is not the invite domain`() {
        // The web invite is https. Accepting http would let anything on the
        // network rewrite a link into a different party.
        assertNull(JamInviteLink.parseInvite("http://bitchord.kushagrasingh.in/invite/ABC123"))
    }

    // ---- The server the invite names ---------------------------------------

    @Test
    fun `a server on the invite is carried through`() {
        val invite = JamInviteLink.parseInvite("bitchord://party/ABC123?server=https://jam.example")
        assertEquals("https://jam.example", invite?.serverUrl)
    }

    @Test
    fun `a server without a scheme is filled in rather than refused`() {
        // `server=jam.example` is what a person types and `server=https://jam.example`
        // is what a tool produces. Both mean the same thing.
        assertEquals("https://jam.example", JamInviteLink.sanitizeServerUrl("jam.example"))
    }

    @Test
    fun `a server keeps the scheme it was given`() {
        assertEquals("http://jam.example", JamInviteLink.sanitizeServerUrl("http://jam.example"))
        assertEquals("https://jam.example", JamInviteLink.sanitizeServerUrl("https://jam.example"))
    }

    @Test
    fun `a trailing slash on the server is dropped`() {
        assertEquals("https://jam.example", JamInviteLink.sanitizeServerUrl("https://jam.example/"))
    }

    @Test
    fun `a server with no host is refused`() {
        // Not a server address, whatever else it is.
        assertNull(JamInviteLink.sanitizeServerUrl("https://"))
        assertNull(JamInviteLink.sanitizeServerUrl("   "))
        assertNull(JamInviteLink.sanitizeServerUrl(null))
    }

    @Test
    fun `a server with a space in it is refused`() {
        assertNull(JamInviteLink.sanitizeServerUrl("https://jam example"))
    }

    @Test
    fun `an invite with no server carries none`() {
        assertNull(JamInviteLink.parseInvite("bitchord://party/ABC123")?.serverUrl)
    }

    // ---- Query parameters -------------------------------------------------

    @Test
    fun `a parameter is matched ignoring case`() {
        assertEquals("ABC123", JamInviteLink.queryParam("Code=ABC123", "code"))
    }

    @Test
    fun `a percent-encoded parameter is decoded`() {
        assertEquals("https://jam.example", JamInviteLink.queryParam("server=https%3A%2F%2Fjam.example", "server"))
    }

    @Test
    fun `a plus is left alone`() {
        // `+` is a space only in form encoding, and rewriting it would corrupt a
        // value that genuinely contains one.
        assertEquals("a+b", JamInviteLink.queryParam("k=a+b", "k"))
    }

    @Test
    fun `a malformed escape is passed through rather than dropped`() {
        assertEquals("100%", JamInviteLink.queryParam("k=100%", "k"))
    }

    @Test
    fun `a parameter with no value is not a parameter`() {
        assertNull(JamInviteLink.queryParam("code", "code"))
        assertNull(JamInviteLink.queryParam("", "code"))
    }

    // ---- Deciding whether to offer to open a link -------------------------

    @Test
    fun `an invite-looking link is recognised even if the code is wrong`() {
        // Whether to *offer* is a different question from whether it *parses*. A
        // link with a stale code should still say so rather than being ignored.
        assertTrue(JamInviteLink.looksLikeInvite("bitchord://party/BADCODE"))
        assertTrue(JamInviteLink.looksLikeInvite("https://bitchord.kushagrasingh.in/invite/ABC123"))
    }

    @Test
    fun `an unrelated link is not offered`() {
        assertFalse(JamInviteLink.looksLikeInvite("https://example.invalid/anything"))
        assertFalse(JamInviteLink.looksLikeInvite(null))
    }
}

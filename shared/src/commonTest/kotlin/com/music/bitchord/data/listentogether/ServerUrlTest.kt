package com.music.bitchord.data.listentogether

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Reading a party server's address.
 *
 * The function's job is not "is this a URL" but "is this the *canonical* form of
 * one", because the result is used as a prefix for every request the device makes.
 * So most of these are about the two properties that follow from that: a
 * normalised address appends cleanly, and two spellings of one server come out
 * byte-identical.
 */
class ServerUrlTest {

    private fun valid(raw: String?): String {
        val result = ServerUrl.parseAndNormalize(raw)
        assertIs<ServerUrlValidationResult.Valid>(result, "expected valid: $raw -> $result")
        return result.normalizedUrl
    }

    private fun error(raw: String?): ServerUrlError {
        val result = ServerUrl.parseAndNormalize(raw)
        assertIs<ServerUrlValidationResult.Invalid>(result, "expected invalid: $raw -> $result")
        return result.error
    }

    // ---- No address is an answer, not a failure ----------------------------

    @Test
    fun `an empty address is valid and means no server`() {
        // The state a fresh install is in, so it has to be representable as an
        // answer rather than as something to apologise for on screen.
        assertEquals("", valid(""))
        assertEquals("", valid("   "))
        assertEquals("", valid(null))
    }

    // ---- Canonical form ----------------------------------------------------

    @Test
    fun `a missing scheme is filled in with https`() {
        assertEquals("https://jam.example", valid("jam.example"))
    }

    @Test
    fun `a trailing slash is removed`() {
        // The single most common thing to get wrong about a base URL, and the least
        // visible when you do: `base + "/api/parties"` would be a doubled separator.
        assertEquals("https://jam.example", valid("https://jam.example/"))
        assertEquals("https://jam.example", valid("jam.example/"))
    }

    @Test
    fun `a host is lower-cased so one server does not look like two`() {
        assertEquals("https://jam.example", valid("https://JAM.Example"))
        assertEquals("http://jam.example", valid("HTTP://JAM.example"))
    }

    @Test
    fun `surrounding whitespace is trimmed`() {
        assertEquals("https://jam.example", valid("  https://jam.example  "))
    }

    @Test
    fun `a sub-path is kept because some deployments live under one`() {
        assertEquals("https://example.com/jam", valid("https://example.com/jam"))
        assertEquals("https://example.com/jam", valid("https://example.com/jam/"))
        assertEquals("https://example.com/jam", valid("https://example.com//jam//"))
    }

    @Test
    fun `a port is kept`() {
        assertEquals("https://jam.example:8443", valid("jam.example:8443"))
        assertEquals("http://192.168.0.252:8000", valid("http://192.168.0.252:8000"))
    }

    @Test
    fun `the scheme's own default port is dropped`() {
        // RFC 3986 scheme-based normalization. Two spellings of one server have to
        // come out identical, or the health cache probes one address while the
        // socket dials another.
        assertEquals("https://jam.example", valid("https://jam.example:443"))
        assertEquals("http://jam.example", valid("http://jam.example:80"))
        // And only the *scheme's* default: 80 on https is a real port.
        assertEquals("https://jam.example:80", valid("https://jam.example:80"))
    }

    @Test
    fun `a lan address is a valid host`() {
        // What a party server on a laptop actually looks like.
        assertEquals("http://192.168.0.252:8000", valid("http://192.168.0.252:8000"))
        assertEquals("https://127.0.0.1:8000", valid("127.0.0.1:8000"))
    }

    @Test
    fun `localhost is allowed though it is one label`() {
        // A party server run on a laptop is the single most common case there is,
        // and it is the one host that legitimately has no dot in it.
        assertEquals("http://localhost:8000", valid("http://localhost:8000"))
        assertEquals("http://localhost:8000", valid("http://LOCALHOST:8000"))
    }

    // ---- Refusals, each for its own reason ---------------------------------

    @Test
    fun `whitespace anywhere is refused`() {
        // Almost always a paste that carried formatting from somewhere else.
        assertEquals(ServerUrlError.Whitespace, error("https://jam example"))
        assertEquals(ServerUrlError.Whitespace, error("https://jam.example\tx"))
    }

    @Test
    fun `a scheme that is not http is refused`() {
        // Named specifically, because `ftp://` is what somebody gets when they
        // paste a URL of the wrong sort and want to know which sort.
        assertEquals(ServerUrlError.InvalidScheme, error("ftp://jam.example"))
        assertEquals(ServerUrlError.InvalidScheme, error("ws://jam.example"))
        assertEquals(ServerUrlError.InvalidScheme, error("file://jam.example"))
    }

    @Test
    fun `a query is refused`() {
        // A query belongs to one URL. Appending a path to a base that has one
        // produces a request whose query *is* the path.
        assertEquals(ServerUrlError.HasQuery, error("https://jam.example?token=x"))
    }

    @Test
    fun `a fragment is refused`() {
        assertEquals(ServerUrlError.HasFragment, error("https://jam.example#top"))
    }

    @Test
    fun `a dot path segment is refused`() {
        // A `..` walks out of the base entirely, and a base is the one thing that
        // must not be walked out of.
        assertEquals(ServerUrlError.InvalidPath, error("https://jam.example/../admin"))
        assertEquals(ServerUrlError.InvalidPath, error("https://jam.example/a/./b"))
    }

    @Test
    fun `a port out of range is refused`() {
        assertEquals(ServerUrlError.InvalidPort, error("jam.example:0"))
        assertEquals(ServerUrlError.InvalidPort, error("jam.example:70000"))
        assertEquals(ServerUrlError.InvalidPort, error("jam.example:99999"))
    }

    @Test
    fun `a port that is not a number is refused`() {
        assertEquals(ServerUrlError.InvalidPort, error("jam.example:port"))
    }

    @Test
    fun `no host at all is refused`() {
        assertEquals(ServerUrlError.InvalidHost, error("https://"))
        assertEquals(ServerUrlError.InvalidHost, error("https:///api"))
    }

    @Test
    fun `a single-label host is refused except localhost`() {
        // `jam` is a real intranet name that would resolve on exactly the network
        // where somebody is typing it — so this is refused on purpose, and the
        // error names the host rather than the URL.
        assertEquals(ServerUrlError.InvalidHost, error("https://jam"))
    }

    @Test
    fun `a malformed label is refused`() {
        // No whitespace in these on purpose: a space is caught by the earlier
        // whitespace rule and reported as whitespace, which is the more useful of
        // the two answers for a paste that arrived with formatting on it.
        assertEquals(ServerUrlError.InvalidHost, error("https://jam.exa_mple"))
        assertEquals(ServerUrlError.InvalidHost, error("https://jam..example"))
        assertEquals(ServerUrlError.InvalidHost, error("https://-jam.example"))
        assertEquals(ServerUrlError.InvalidHost, error("https://jam-.example"))
    }

    @Test
    fun `a leading or trailing dot on the host is refused`() {
        // Not a typo to be tolerated: a resolver treats a trailing dot as
        // meaningful and a leading one as nothing at all.
        assertEquals(ServerUrlError.InvalidHost, error("https://jam.example."))
        assertEquals(ServerUrlError.InvalidHost, error("https://.jam.example"))
    }

    @Test
    fun `an over-long label is refused`() {
        val long = "a".repeat(64)
        assertEquals(ServerUrlError.InvalidHost, error("https://jam.$long"))
    }

    // ---- IPv6 --------------------------------------------------------------

    @Test
    fun `an ipv6 literal keeps its brackets and its port`() {
        // The bracket check is the whole reason the authority is not split on `:` —
        // without it `[::1]:8000` loses its port.
        assertEquals("http://[::1]:8000", valid("http://[::1]:8000"))
        assertEquals("http://[::1]", valid("http://[::1]"))
    }

    @Test
    fun `an ipv6 literal is lower-cased`() {
        assertEquals("http://[2001:db8::1]", valid("http://[2001:DB8::1]"))
    }

    // ---- What the normalisation is for -------------------------------------

    @Test
    fun `the result appends a path without doubling the separator`() {
        // Stated as a property rather than a string comparison, because this is the
        // entire reason the function exists.
        val base = valid("https://jam.example/")
        assertEquals("https://jam.example/api/parties", base + "/api/parties")
        assertTrue(!base.contains("//api"))
    }

    @Test
    fun `every spelling of one server normalises to the same string`() {
        // Or the same server looks like two — to the cache, and to the user's eyes.
        val spellings = listOf(
            "jam.example",
            "JAM.example",
            "https://jam.example",
            "https://jam.example/",
            "  https://jam.example/  ",
            "https://jam.example:443",
        ).map { valid(it) }
        assertEquals(1, spellings.distinct().size, "diverged: $spellings")
        // Scheme is *not* normalized away, and must not be: http and https are two
        // different servers however alike the host.
        assertTrue(valid("http://jam.example") != valid("https://jam.example"))
    }
}

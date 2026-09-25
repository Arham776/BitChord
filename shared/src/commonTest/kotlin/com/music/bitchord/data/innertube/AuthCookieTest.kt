package com.music.bitchord.data.innertube

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of upstream `AuthCookieTest.kt`, plus the SAPISID lookup it guards.
 *
 * This is the one piece of session logic where being subtly wrong fails
 * *silently* rather than loudly, which is what makes it worth pinning down.
 *
 * The test used to be a substring check for `SAPISID`, and `__Secure-3PAPISID`
 * contains "SAPISID" — so a jar holding only the `__Secure-` forms, which is
 * what a partitioned-cookie login produces, passed a check for a cookie it did
 * not have. The app then declared itself signed in and made every request
 * unsigned, which Google answers as a request from nobody. Library reads
 * degraded quietly and history was never written at all.
 */
class AuthCookieTest {

    @Test
    fun findsThePlainSigningSecret() {
        assertTrue(Innertube.hasApiSid("SID=abc; SAPISID=secret; HSID=def"))
    }

    @Test
    fun findsTheThirdPartySecureForm() {
        // A `__Host-`/partitioned login sets only the `__Secure-` forms. All three
        // names carry the same secret and any of them signs a request.
        assertTrue(Innertube.hasApiSid("SID=abc; __Secure-3PAPISID=secret"))
        assertTrue(Innertube.hasApiSid("SID=abc; __Secure-1PAPISID=secret"))
    }

    @Test
    fun toleratesNoSpaceAfterEachSeparator() {
        assertTrue(Innertube.hasApiSid("SID=abc; SAPISID=secret;HSID=def"))
    }

    @Test
    fun toleratesWhitespaceAroundTheName() {
        assertTrue(Innertube.hasApiSid("  SAPISID = secret  "))
    }

    @Test
    fun rejectsAJarWithNoSigningSecret() {
        assertFalse(Innertube.hasApiSid("SID=abc; HSID=def; SSID=ghi; APISID=jkl"))
        assertFalse(Innertube.hasApiSid(""))
    }

    @Test
    fun rejectsAnEmptyValue() {
        // The name is there and the secret is not. A check that only looked at the
        // name would pass this and then sign a request with nothing.
        assertFalse(Innertube.hasApiSid("SID=abc; SAPISID=; HSID=def"))
    }

    @Test
    fun matchesOnTheWholeNameNotASubstring() {
        assertFalse(Innertube.hasApiSid("APISID=secret"))
        assertFalse(Innertube.hasApiSid("NOT-SAPISID=secret"))
        assertFalse(Innertube.hasApiSid("PREF=tz=SAPISID"))
    }

    @Test
    fun extractsTheSecretForSigning() {
        assertEquals("secret", Innertube.sapisidFrom("SID=abc; SAPISID=secret; HSID=def"))
        assertEquals("secret", Innertube.sapisidFrom("SID=abc; __Secure-3PAPISID=secret"))
        assertNull(Innertube.sapisidFrom("SID=abc; HSID=def"))
    }

    @Test
    fun prefersThePlainFormWhenSeveralArePresent() {
        // Order matters: the plain form is first because that is what Google's own
        // origin-scoped hash is documented against. All three hold the same value
        // in practice, so this only matters when they do not.
        assertEquals("plain", Innertube.sapisidFrom("SAPISID=plain; __Secure-3PAPISID=third"))
    }

    @Test
    fun signsWithGooglesScheme() {
        val header = Innertube.sapisidHash("secret", "https://music.youtube.com")
        assertTrue(header.startsWith("SAPISIDHASH "), "was: $header")
        // `<unix seconds>_<40 hex chars>` — SHA-1 is Google's choice here, not ours.
        val payload = header.removePrefix("SAPISIDHASH ")
        val (timestamp, digest) = payload.split("_", limit = 2)
        assertTrue(timestamp.toLongOrNull() != null, "timestamp was: $timestamp")
        assertEquals(40, digest.length, "digest was: $digest")
        assertTrue(digest.all { it in "0123456789abcdef" }, "digest was: $digest")
    }

    @Test
    fun signsForTheOriginTheRequestIsGoingTo() {
        // Google recomputes the digest over the origin it sees and rejects a
        // mismatch with 401, so a request signed for the music origin and sent to
        // www.youtube.com is a refused one rather than a weaker one. The two must
        // therefore not produce the same header.
        val music = Innertube.sapisidHash("secret", "https://music.youtube.com")
        val youtube = Innertube.sapisidHash("secret", "https://www.youtube.com")
        assertNotNull(music)
        assertTrue(music != youtube, "signatures collided across origins")
    }
}

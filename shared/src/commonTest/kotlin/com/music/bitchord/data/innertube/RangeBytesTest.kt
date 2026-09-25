package com.music.bitchord.data.innertube

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The range a googlevideo URL will serve is a property of the client that
 * minted it, not a constant.
 *
 * This is pinned by tests because getting it wrong is invisible in a unit test
 * and very visible in use. A probe that asks for more than the client will serve
 * takes the refusal as evidence about the *client*, stands down something that
 * was working, and does so again on every track — a client that works perfectly
 * well never gets used. A downloader that asks for too much produces a track
 * that starts and then dies one range in, which reads as "it loads and then
 * doesn't play" and is indistinguishable from a network problem.
 */
class RangeBytesTest {

    private fun url(client: String, extra: String = ""): String =
        "https://rr3---sn-abc.googlevideo.com/videoplayback?expire=1&c=$client&itag=140$extra"

    @Test
    fun `a full-width client serves a megabyte`() {
        assertEquals(
            PlayerClient.RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("ANDROID_MUSIC")),
        )
        assertEquals(
            PlayerClient.RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("WEB_REMIX")),
        )
        assertEquals(
            PlayerClient.RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("IOS")),
        )
    }

    @Test
    fun `a narrow client serves half a megabyte and asking for more is a refusal`() {
        // ANDROID_VR and TVHTML5_SIMPLY cap at half. A 1 MiB request to one of
        // these URLs is answered 403, which is why the probe must consult this
        // rather than assuming every client is the same.
        assertEquals(
            PlayerClient.NARROW_RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("ANDROID_VR")),
        )
        assertEquals(
            PlayerClient.NARROW_RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("TVHTML5_SIMPLY")),
        )
        assertTrue(PlayerClient.RANGE_BYTES > PlayerClient.NARROW_RANGE_BYTES)
    }

    @Test
    fun `the narrow client's own sibling is not narrow`() {
        // TVHTML5 is a different client from TVHTML5_SIMPLY and is not capped.
        // The rule keys on the SIMPLY prefix, not on "TVHTML5".
        assertEquals(
            PlayerClient.RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("TVHTML5")),
        )
    }

    @Test
    fun `the client's case does not matter`() {
        assertEquals(
            PlayerClient.NARROW_RANGE_BYTES,
            PlayerClient.rangeBytesFor(url("android_vr")),
        )
    }

    @Test
    fun `a URL naming no client is asked the full range`() {
        assertEquals(
            PlayerClient.RANGE_BYTES,
            PlayerClient.rangeBytesFor("https://rr3---sn-abc.googlevideo.com/videoplayback?itag=140"),
        )
    }

    @Test
    fun `a host that is not googlevideo's cap is nobody else's business`() {
        // The limit is Google's. A module's or addon's own CDN serves what it
        // likes, and being handed Long.MAX_VALUE is what tells the caller not to
        // invent a limit of its own.
        assertEquals(
            Long.MAX_VALUE,
            PlayerClient.rangeBytesFor("https://cdn.example.invalid/audio/song.flac"),
        )
    }

    @Test
    fun `the total length comes off the URL for free`() {
        assertEquals(
            4_194_304L,
            PlayerClient.lengthFromUrl("https://x.googlevideo.com/v?clen=4194304&c=IOS"),
        )
    }

    @Test
    fun `a URL with no length says so rather than guessing zero`() {
        // The probe treats null as "unknown" and asks its normal range. Reading
        // it as 0 would clamp every range to nothing and refuse every URL.
        assertNull(PlayerClient.lengthFromUrl("https://x.googlevideo.com/v?c=IOS"))
        assertNull(PlayerClient.lengthFromUrl("https://x.googlevideo.com/v?clen=abc&c=IOS"))
        assertNull(PlayerClient.lengthFromUrl("https://x.googlevideo.com/v"))
    }

    @Test
    fun `length is read past the other parameters`() {
        assertEquals(
            12_345L,
            PlayerClient.lengthFromUrl(
                "https://x.googlevideo.com/v?expire=1&ratebypass=yes&clen=12345&c=ANDROID_MUSIC"
            ),
        )
    }
}

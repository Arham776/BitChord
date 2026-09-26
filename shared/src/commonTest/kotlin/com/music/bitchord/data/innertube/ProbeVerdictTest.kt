package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.ProbeResult
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * What a ranged GET on a minted stream URL is allowed to mean.
 *
 * Written because of the bug that made this a class worth testing: the verdict used
 * to insist the content type begin `audio/`, and a guest session is handed a muxed
 * `video/mp4` carrying AAC for most of the catalogue. The resolver takes that format
 * on purpose — it is what is left when adaptive audio is SABR-only — and the engine
 * demuxes the audio out of it. So the test threw away the only rung the ladder had,
 * and the symptom was a track that resolved on nothing at all, with every client
 * reporting a refusal for a URL that was fine.
 *
 * These are the shapes a real answer takes: a media type, an error page, a range past
 * the end, a bot check.
 */
class ProbeVerdictTest {

    private val muxed = "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\""
    private val audioOnly = "audio/mp4; codecs=\"mp4a.40.2\""

    private fun probe(
        status: Int,
        contentType: String? = null,
        bodyArrived: Boolean = true,
    ) = ProbeResult(status = status, contentType = contentType, bodyArrived = bodyArrived)

    // ---- The bug ------------------------------------------------------------

    @Test
    fun `a muxed format's own answer is playable`() {
        assertEquals(ProbeVerdict.OK, probe(206, "video/mp4").classify(muxed))
        assertEquals(ProbeVerdict.OK, probe(200, "video/mp4").classify(muxed))
    }

    @Test
    fun `an audio-only format's own answer is playable`() {
        assertEquals(ProbeVerdict.OK, probe(206, "audio/mp4").classify(audioOnly))
    }

    @Test
    fun `the codec list is not part of the comparison`() {
        // The expected value is a full mime type with parameters; the answer is a bare
        // family. Comparing them for equality would refuse both of these.
        assertEquals(ProbeVerdict.OK, probe(206, "video/mp4").classify(muxed))
        assertEquals(ProbeVerdict.OK, probe(206, "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"").classify(muxed))
    }

    @Test
    fun `a different family is a different file`() {
        // An audio-only URL answering `video/mp4` is not this format with a sloppy
        // label; it is something else, and a range on it would hand the engine a
        // container it did not ask for.
        assertEquals(ProbeVerdict.REFUSED, probe(206, "video/mp4").classify(audioOnly))
        assertEquals(ProbeVerdict.REFUSED, probe(206, "audio/mp4").classify(muxed))
    }

    // ---- What is still refused ---------------------------------------------

    @Test
    fun `an error page is refused whatever the format`() {
        // The case the content-type test is actually for: a bot check or a consent
        // page answers 200 with HTML, and its bytes arrive.
        assertEquals(ProbeVerdict.REFUSED, probe(200, "text/html; charset=utf-8").classify(muxed))
        assertEquals(ProbeVerdict.REFUSED, probe(200, "text/html").classify(audioOnly))
        assertEquals(ProbeVerdict.REFUSED, probe(200, "application/json").classify(audioOnly))
    }

    @Test
    fun `a refusal is the client's problem and not a bad minute`() {
        listOf(403, 404, 410).forEach { status ->
            assertEquals(ProbeVerdict.REFUSED, probe(status, "video/mp4").classify(muxed), "$status")
        }
    }

    @Test
    fun `no answer at all blames nobody in particular`() {
        assertEquals(ProbeVerdict.UNREACHABLE, probe(0, null, bodyArrived = false).classify(muxed))
        assertEquals(ProbeVerdict.UNREACHABLE, probe(503, null, bodyArrived = false).classify(muxed))
    }

    @Test
    fun `media that was asked for but never arrived is not playable`() {
        // Distinct from a refusal on purpose: the client is fine, the network was not,
        // and standing a client down on this would take a good one out of service.
        assertEquals(ProbeVerdict.UNREACHABLE, probe(206, "video/mp4", bodyArrived = false).classify(muxed))
    }

    @Test
    fun `a range past the end is the end and not a failure`() {
        // 416 on a seek past the container's length: the same end the Rust reader
        // treats as a clean finish.
        assertEquals(ProbeVerdict.UNREACHABLE, probe(416, null, bodyArrived = false).classify(muxed))
    }

    @Test
    fun `a server that declines to name a type is not naming a wrong one`() {
        assertEquals(ProbeVerdict.OK, probe(206, "application/octet-stream").classify(muxed))
        assertEquals(ProbeVerdict.OK, probe(206, "application/octet-stream").classify(audioOnly))
    }

    // ---- When nothing was asked for ----------------------------------------

    @Test
    fun `with no format to compare against only the wrong answers are refused`() {
        // The seam's default: a caller that has not said what it wanted still gets the
        // error-page check, and nothing stricter.
        assertEquals(ProbeVerdict.OK, probe(206, "video/mp4").classify())
        assertEquals(ProbeVerdict.OK, probe(206, "audio/mp4").classify())
        assertEquals(ProbeVerdict.REFUSED, probe(200, "text/html").classify())
        assertEquals(ProbeVerdict.REFUSED, probe(206, null).classify())
    }

    @Test
    fun `a content type with a charset is still a content type`() {
        assertEquals(ProbeVerdict.OK, probe(206, "video/mp4; charset=utf-8").classify(muxed))
        assertEquals(ProbeVerdict.OK, probe(206, "  VIDEO/MP4  ").classify(muxed))
    }
}

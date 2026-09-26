package com.music.bitchord.data

import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Whether the build running here is behind the one on the project's releases.
 *
 * The comparison is a judgement with edges on every side — tags with and without a
 * `v`, a two-part version, a ten-part number, a prerelease — and getting one of them
 * wrong is an update notice that either never appears or appears for a build the
 * listener is already running. Upstream's rule is ported verbatim including the
 * prerelease clause, which is the line that decides both of those.
 */
class AppUpdateCheckerTest {

    private val json = Json { ignoreUnknownKeys = true }

    /** The reader lives on the object, so every call goes through its scope. */
    private fun kotlinx.serialization.json.JsonElement.releaseInfo() =
        with(AppUpdateChecker) { releaseInfo() }

    @Test
    fun `a higher version is newer`() {
        assertTrue(AppUpdateChecker.isNewer(latest = "1.0.1", current = "1.0.0"))
        assertTrue(AppUpdateChecker.isNewer(latest = "1.1.0", current = "1.0.9"))
        assertTrue(AppUpdateChecker.isNewer(latest = "2.0.0", current = "1.9.9"))
    }

    @Test
    fun `the same version is not newer`() {
        assertFalse(AppUpdateChecker.isNewer(latest = "1.0.0", current = "1.0.0"))
    }

    @Test
    fun `a lower version is not newer`() {
        assertFalse(AppUpdateChecker.isNewer(latest = "1.0.0", current = "1.0.1"))
        assertFalse(AppUpdateChecker.isNewer(latest = "0.9.9", current = "1.0.0"))
    }

    @Test
    fun `numbers are compared as numbers and not as text`() {
        // The one that catches a lexicographic comparison: "1.0.10" is *after*
        // "1.0.9", and as text it is before.
        assertTrue(AppUpdateChecker.isNewer(latest = "1.0.10", current = "1.0.9"))
        assertTrue(AppUpdateChecker.isNewer(latest = "1.10.0", current = "1.9.0"))
    }

    @Test
    fun `a missing part counts as zero`() {
        // A tag written `1.1` and a build version written `1.1.0` are the same thing.
        assertFalse(AppUpdateChecker.isNewer(latest = "1.1", current = "1.1.0"))
        assertFalse(AppUpdateChecker.isNewer(latest = "1.1.0", current = "1.1"))
        assertTrue(AppUpdateChecker.isNewer(latest = "1.2", current = "1.1.9"))
    }

    @Test
    fun `a v prefix is not part of the version`() {
        // Upstream's releases are tagged `v1.2.3` and the build is `1.2.3`, so this is
        // the case that happens on every single check rather than an edge.
        assertFalse(AppUpdateChecker.isNewer(latest = "v1.2.3", current = "1.2.3"))
        assertTrue(AppUpdateChecker.isNewer(latest = "v1.2.4", current = "1.2.3"))
        assertTrue(AppUpdateChecker.isNewer(latest = "V1.2.4", current = "1.2.3"))
    }

    @Test
    fun `a prerelease does not supersede the release it leads up to`() {
        // The line worth having. `2.0.0-rc1` has a bigger number than `1.9.0` and is
        // older than it, and comparing the numbers alone would offer a release
        // candidate as an upgrade to somebody on the last stable.
        assertFalse(AppUpdateChecker.isNewer(latest = "2.0.0-rc1", current = "1.9.0"))
        // And the pair that is not symmetric: the numbers still decide downwards, so
        // 1.9.0 is not an update to a 2.0.0 candidate either.
        assertFalse(AppUpdateChecker.isNewer(latest = "1.9.0", current = "2.0.0-rc1"))
        // The same numbers is upstream's case, and the one a listener on a beta
        // actually hits: the final release supersedes the candidate for it.
        assertTrue(AppUpdateChecker.isNewer(latest = "1.9.0", current = "1.9.0-rc1"))
    }

    @Test
    fun `two prereleases of the same numbers are the same version here`() {
        // Upstream's limit, kept rather than papered over: comparing the labels would
        // need an ordering for `rc10` against `rc9` that tags do not reliably carry.
        // Nobody is offered an RC over an RC, which is the direction that would have
        // mattered.
        assertFalse(AppUpdateChecker.isNewer(latest = "2.0.0-rc2", current = "2.0.0-rc1"))
        assertFalse(AppUpdateChecker.isNewer(latest = "2.0.0-rc1", current = "2.0.0-rc2"))
    }

    @Test
    fun `a build suffix is not a prerelease`() {
        // `1.2.3+build.7` is the same release built again, not an earlier one.
        assertFalse(AppUpdateChecker.isNewer(latest = "1.2.3+build.7", current = "1.2.3"))
    }

    @Test
    fun `a tag with no numbers is version zero rather than a refusal`() {
        // A release called `nightly` must not make the app claim it is behind on
        // every launch, which is what an exception here would do.
        assertFalse(AppUpdateChecker.isNewer(latest = "nightly", current = "0.0.1"))
        assertTrue(AppUpdateChecker.isNewer(latest = "0.0.1", current = "nightly"))
    }

    @Test
    fun `a part with a word in it is not a number at all`() {
        // Upstream's rule: the whole part parses or it is nothing. `1.2.3beta` is
        // 1.2.0, not 1.2.3, so a malformed tag cannot claim an upgrade from a version
        // it was never tagged as.
        assertEquals(listOf(1, 2, 0), AppUpdateChecker.parseVersion("1.2.3beta").parts)
        assertEquals(listOf(1, 2, 3), AppUpdateChecker.parseVersion("1.2.3").parts)
    }

    // ---- The release object ------------------------------------------------

    @Test
    fun `a release object is read for its tag its page and its notes`() {
        val info = release(
            tag = "v2.1.0",
            url = "https://github.com/kushagrasinghx/BitChord/releases/tag/v2.1.0",
            body = "## What's new\n- WebDAV\n",
        )
        assertEquals("2.1.0", info?.version)
        assertEquals("https://github.com/kushagrasinghx/BitChord/releases/tag/v2.1.0", info?.releaseUrl)
        assertEquals("## What's new\n- WebDAV", info?.notes)
    }

    @Test
    fun `a release with no notes is still a release`() {
        val info = release(tag = "v2.1.0", url = "https://example.com/r", body = "   ")
        assertEquals("2.1.0", info?.version)
        assertNull(info?.notes, "blank notes are no notes, and an empty string is not a sentence")
    }

    @Test
    fun `a release with no link is nothing to show`() {
        // A notice with a blank link is a dead button; there is nothing to open.
        assertNull(release(tag = "v2.1.0", url = null, body = "notes"))
        assertNull(release(tag = null, url = "https://example.com/r", body = "notes"))
    }

    @Test
    fun `a body that is not a release object is nothing to show`() {
        // A rate-limit body, an HTML error page, a proxy's JSON: all of them land on a
        // null rather than on a notice or a crash.
        assertNull(json.parseToJsonElement("""{"message":"API rate limit exceeded"}""").releaseInfo())
        assertNull(json.parseToJsonElement("[]").releaseInfo())
        assertNull(json.parseToJsonElement("\"not an object\"").releaseInfo())
    }

    /** A release object as GitHub writes it, built rather than pasted. */
    private fun release(tag: String?, url: String?, body: String?): AppUpdateChecker.UpdateInfo? {
        val fields = buildList {
            tag?.let { add("\"tag_name\": ${quote(it)}") }
            url?.let { add("\"html_url\": ${quote(it)}") }
            body?.let { add("\"body\": ${quote(it)}") }
            add("\"draft\": false")
            add("\"prerelease\": false")
        }
        return json.parseToJsonElement("{${fields.joinToString(",")}}").releaseInfo()
    }

    private fun quote(value: String) = "\"" + value
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n") + "\""
}

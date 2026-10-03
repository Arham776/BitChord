package com.music.bitchord.data

import com.music.bitchord.data.http.Http
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * Whether the build running here is behind the one on the project's releases.
 *
 * Port of upstream `data/AppUpdateChecker.kt`, with the two Android halves left off
 * and the reason worth stating, because the port is smaller than the original and
 * that is a decision rather than an omission.
 *
 * Upstream ships as a sideloaded APK off GitHub Releases, so it polls the repo's
 * latest release once per launch, compares the tag with `BuildConfig.VERSION_NAME`,
 * and — the reason the object is four screens long — downloads the release's `.apk`
 * into its own cache and hands it to the system package installer, so the whole
 * update stays inside the app.
 *
 * On this platform the detection and the notes are worth having and the install is
 * not: there is no in-app installer, a build is a `.app` bundle or a TestFlight
 * build, and "Install Now" would be a button that cannot do what it says. So the
 * portable half is here — poll, compare, carry the release notes — and the update
 * itself is a link to the release, which is the platform's own answer. Upstream's
 * release page is this project's release page, so a listener who reads the notes
 * here and installs there is looking at the same release.
 */
object AppUpdateChecker {

    /**
     * A release, as far as anything here needs it.
     *
     * @param version the tag with any leading `v` removed
     * @param releaseUrl where the release is, which is where an install happens on
     *   this platform
     * @param notes the release's own Markdown body, shown as the "what's new"
     */
    data class UpdateInfo(
        val version: String,
        val releaseUrl: String,
        val notes: String?,
    )

    private const val LATEST_RELEASE_URL =
        "https://api.github.com/repos/bagumamartin/BitChord/releases/latest"

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The latest release, or null when there is not one to be had.
     *
     * Null for every way this can fail — not configured, offline, rate limited, a
     * body that is not the shape it was — because a check that fails is not an
     * update notice, and a notice that says "there might be an update" is worse than
     * silence. The reason is not carried: there is nothing anybody could do with it.
     *
     * This reaches the network, so it is called on demand and at most once per
     * launch. GitHub rate limits an unauthenticated caller to a few dozen requests an
     * hour per address, which is a budget a listener should not spend on a poll.
     */
    suspend fun latest(): UpdateInfo? {
        val response = runCatching {
            Http.getRaw(
                url = LATEST_RELEASE_URL,
                headers = mapOf("Accept" to "application/vnd.github+json"),
                timeoutMillis = 10_000,
            )
        }.getOrNull() ?: return null
        if (response.status !in 200..299) return null
        val body = response.body ?: return null
        val release = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull()
            ?: return null
        return release.toUpdateInfo()
    }

    /**
     * The release described by a GitHub release object, or null — for any element at
     * all, so a body that is an array or a string is a null rather than a crash.
     *
     * Internal and pure so the shape can be tested without the network — the fields
     * are the ones that have to be right for anything to be shown, and a body that
     * loses one of them must be a null rather than a notice with a blank link.
     */
    internal fun JsonElement.releaseInfo(): UpdateInfo? = (this as? JsonObject)?.toUpdateInfo()

    internal fun JsonObject.toUpdateInfo(): UpdateInfo? {
        val tag = string("tag_name")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val url = string("html_url")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return UpdateInfo(
            version = tag.removePrefix("v").removePrefix("V"),
            releaseUrl = url,
            notes = string("body")?.trim()?.takeIf { it.isNotEmpty() },
        )
    }

    private fun JsonObject.string(key: String): String? =
        runCatching { this[key]?.jsonPrimitive?.contentOrNull }.getOrNull()

    /**
     * Whether [latest] is a build worth moving to from [current].
     *
     * Upstream's rule with one addition, and the addition is the only part worth
     * arguing about.
     *
     * Upstream compares the numbers and then asks, for equal numbers, whether the one
     * being left behind is a prerelease — so `1.9.0-rc1` is correctly not an update to
     * `1.9.0`. It does not apply that reasoning when the *numbers* differ, and
     * `2.0.0-rc1` against `1.9.0` comes out as newer: a release candidate offered to
     * somebody on the last stable, which is the one thing an update notice should
     * never do. So a prerelease here never outranks a release, whatever the numbers
     * say, and everything else is upstream's.
     *
     * The limit that leaves is upstream's too: two prereleases of the same numbers
     * compare equal, so `2.0.0-rc2` is not an update to `2.0.0-rc1`. Comparing the
     * labels would fix it and would need an ordering for `rc10` against `rc9` that
     * tags do not reliably carry, so the comparison stays on the numbers.
     */
    fun isNewer(latest: String, current: String): Boolean {
        val l = parseVersion(latest)
        val c = parseVersion(current)
        for (i in 0 until maxOf(l.parts.size, c.parts.size)) {
            val a = l.parts.getOrElse(i) { 0 }
            val b = c.parts.getOrElse(i) { 0 }
            if (a != b) {
                // A release candidate is a preview of a version that does not exist
                // yet, so it is not an upgrade from a version that does.
                if (l.isPreRelease && !c.isPreRelease) return false
                return a > b
            }
        }
        return c.isPreRelease && !l.isPreRelease
    }

    /** A version as its numbers and whether it is a prerelease. */
    internal data class Version(val parts: List<Int>, val isPreRelease: Boolean)

    /**
     * `1.2.3`, `v1.2.3`, `1.2.3-rc1`, `1.2.3+build`.
     *
     * Lenient on purpose, because a tag is a person typing: anything that is not a
     * digit ends the numbers, and a `-` or `+` marks the prerelease. A tag with no
     * numbers at all is version zero rather than a refusal, so a release called
     * "nightly" cannot make the app claim it is behind on every launch.
     */
    internal fun parseVersion(raw: String): Version {
        val text = raw.trim().removePrefix("v").removePrefix("V")
        val prereleaseAt = text.indexOfFirst { it == '-' || it == '+' }
        val numbers = if (prereleaseAt < 0) text else text.substring(0, prereleaseAt)
        // A whole part is a number or it is nothing, as upstream has it: `1.2.3beta`
        // reads as 1.2.0 rather than as 1.2.3, and a malformed tag must not be able to
        // claim an upgrade from a version it never was.
        val parts = numbers.split('.').map { it.toIntOrNull() ?: 0 }
        return Version(
            parts = parts.ifEmpty { listOf(0) },
            isPreRelease = prereleaseAt >= 0 && text.getOrNull(prereleaseAt) == '-',
        )
    }
}

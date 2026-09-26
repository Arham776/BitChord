package com.music.bitchord.data.auth

import com.music.bitchord.data.crypto.Sha256
import kotlinx.serialization.Serializable

/**
 * One signed-in Google account, and the YouTube identities available under it.
 * Upstream `GoogleAccountSession`, ported whole.
 *
 * A Google account can own more than one YouTube identity — a personal channel
 * and any number of brand channels — and the shell can only report the one
 * music.youtube.com serves by default. [YouTubeProfile] is the list of the rest.
 */
@Serializable
data class GoogleAccountSession(
    val accountId: String,
    val cookie: String,
    val name: String = "",
    val email: String = "",
    val profiles: List<YouTubeProfile> = emptyList(),
    val activeProfileId: String? = null,
)

/** One Personal or Brand identity available under a Google login. */
@Serializable
data class YouTubeProfile(
    val profileId: String,
    val name: String,
    val handle: String = "",
    val avatar: String? = null,
    val pageId: String? = null,
    val dataSyncId: String? = null,
    val authUser: String? = null,
    val isBrandAccount: Boolean = false,
)

/**
 * The account in effect and the identity chosen under it.
 *
 * A named pair rather than `kotlin.Pair`, for the export reason documented on
 * [AccountStore.activeSelection]: a `Pair` reaches Swift as two optionals.
 */
@Serializable
data class ActiveSelection(
    val account: GoogleAccountSession,
    val profile: YouTubeProfile,
)

/**
 * The stable name for a stored account when Google did not give us one.
 *
 * `dataSyncId` first, because it is the identity the requests actually carry and
 * so is the one that has to be stable across a re-login. The cookie's digest is
 * the fallback: it is stable for as long as the cookie is, and an account we
 * only have a cookie for is still an account. Truncated to 24 hex characters
 * because the value ends up in a settings string a human may read, not because
 * 24 is a meaningful amount of entropy.
 */
fun sessionIdOf(cookie: String, dataSyncId: String?): String =
    dataSyncId?.takeIf { it.isNotBlank() } ?: sha256Hex(cookie).take(24)

/**
 * The stable name for a profile.
 *
 * `pageId`, then `dataSyncId`, then a digest of the name. The first two are
 * Google's own identifiers and are what should be used whenever either is
 * present. The name digest is the last resort and is deliberately weak: a name
 * is not unique, so two identically-named channels collide here. That is
 * acceptable because the alternative is inventing an id that changes on every
 * launch, and a *stable* wrong answer is far easier to live with than an
 * unstable right one — the collision shows up as one profile's selection
 * carrying over to the other, where an unstable id shows up as the selection
 * being forgotten on every relaunch.
 */
fun profileIdOf(pageId: String?, dataSyncId: String?, name: String): String =
    pageId?.takeIf { it.isNotBlank() }
        ?: dataSyncId?.takeIf { it.isNotBlank() }
        ?: "profile:${sha256Hex(name).take(16)}"

/**
 * Lowercase hex, because these ids go into a settings string and into a
 * selector's identity — and two spellings of the same digest would be two
 * different profiles as far as anything comparing them is concerned.
 */
private fun sha256Hex(value: String): String =
    Sha256.digest(value.encodeToByteArray())
        .joinToString("") { byte ->
            val v = byte.toInt() and 0xff
            val digits = "0123456789abcdef"
            "${digits[v shr 4]}${digits[v and 0xf]}"
        }

/**
 * Stable order for the selector and its swipe: account insertion order, then
 * profile order within an account.
 *
 * Deliberately the stored order rather than a sort. Alphabetical would move a
 * listener's second account to the top the moment they added a third, and the
 * whole point of the ordering being stable is that muscle memory survives.
 */
fun flattenedProfiles(accounts: List<GoogleAccountSession>): List<Pair<String, String>> =
    accounts.flatMap { account -> account.profiles.map { account.accountId to it.profileId } }

/**
 * The next or previous profile in selector order, or null at either end.
 *
 * Returning null rather than wrapping is deliberate: a swipe past the last
 * profile should do nothing visible, not teleport the listener from their
 * newest channel to their oldest.
 */
fun adjacentProfile(
    accounts: List<GoogleAccountSession>,
    accountId: String?,
    profileId: String?,
    forward: Boolean,
): Pair<String, String>? {
    val items = flattenedProfiles(accounts)
    val index = items.indexOf(accountId to profileId)
    if (index < 0) return null
    val step = if (forward) 1 else -1
    return items.getOrNull(index + step)
}

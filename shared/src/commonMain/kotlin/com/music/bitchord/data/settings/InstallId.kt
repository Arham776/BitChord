@file:OptIn(ExperimentalAtomicApi::class)

package com.music.bitchord.data.settings

import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.random.Random

/**
 * This install's identifier: one random UUID, minted once, kept until the app is
 * removed.
 *
 * ## What it is for
 *
 * Anything that has to tell *this installation* apart from every other one without
 * knowing who is signed in. Listen Together is the first consumer, and it is not a
 * small one: the party server identifies a member by their device, so a constant
 * here means the second Mac to join a party is refused as a duplicate of the first.
 *
 * ## The three properties that make it usable
 *
 * - **Stable.** Read a hundred times in a session, or after a restart, and it is the
 *   same string. Anything that generated one per read would make every request look
 *   like a new device, and a party would fill with ghosts.
 * - **Independent of the account.** It survives a sign-out, an account switch and a
 *   process death. The alternative — deriving it from who is signed in — would let a
 *   listener fill their own party to the member limit by signing in and out.
 * - **Not in a backup.** A device id restored onto a *different* machine is two
 *   machines claiming one identity, which is the exact collision this exists to
 *   prevent. `NSUserDefaults` is in the iCloud and Finder backups by default, so this
 *   is the reason it is deliberately absent from [AppSettings.exportPrefsJson]'s key
 *   list rather than merely unnoticed there.
 */
object InstallId {

    private const val KEY = "install_id"

    /**
     * The answer, once known.
     *
     * An atomic reference rather than a lock: [get] is called on every join, and the
     * only write is the first one. The value is also written to storage, so a lost
     * race costs a re-read rather than a wrong answer — see the re-read in [get].
     */
    private val cached = AtomicReference<String?>(null)

    /**
     * This install's id, minting one on the first call.
     *
     * Cheap to call from anywhere, including from a background thread, and safe to
     * call twice at once.
     */
    fun get(): String {
        cached.load()?.let { return it }
        val minted = reuseOrMint(
            stored = PlatformSettings.getString(KEY, ""),
            mint = ::mint,
            persist = { PlatformSettings.putString(KEY, it) },
        )
        // If another thread minted at the same moment it may have stored a different
        // id, and the *stored* one is the one this install will report from now on.
        // Re-reading rather than returning our own copy is what makes that race
        // resolve to a single answer instead of two ids in one session.
        val settled = PlatformSettings.getString(KEY, "").ifEmpty { minted }
        cached.store(settled)
        return settled
    }

    /**
     * The whole rule, with the storage handed in.
     *
     * Separate from [get] because the rule is the part worth testing and
     * `PlatformSettings` is a singleton over `NSUserDefaults` — a test that wrote to
     * it would leave state behind for every other test in the build.
     *
     * @param stored what is on disk, possibly blank
     * @param mint produces a fresh id
     * @param persist writes it out
     */
    internal fun reuseOrMint(stored: String?, mint: () -> String, persist: (String) -> Unit): String {
        val existing = stored?.trim().orEmpty()
        if (existing.isNotEmpty()) return existing
        val fresh = mint()
        persist(fresh)
        return fresh
    }

    /**
     * A random UUID, in the canonical 8-4-4-4-12 hex form.
     *
     * Formatted as a UUID rather than as 32 hex characters because that is what a
     * reader of a party server's logs will expect to see, and because anything that
     * ever validates the shape will accept it. The version and variant bits are set
     * to the RFC 4122 values, so the value is a well-formed UUID and not merely a
     * hex string that looks like one.
     *
     * Internal rather than private so the shape can be asserted without going
     * through [get], which would write to the real `NSUserDefaults` from a test.
     */
    internal fun mint(): String {
        val bytes = Random.nextBytes(16)
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x40).toByte() // version 4
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte() // variant 1
        val hex = bytes.joinToString("") { byte ->
            val value = byte.toInt() and 0xFF
            HEX[value ushr 4].toString() + HEX[value and 0x0F]
        }
        return buildString(36) {
            append(hex, 0, 8); append('-')
            append(hex, 8, 12); append('-')
            append(hex, 12, 16); append('-')
            append(hex, 16, 20); append('-')
            append(hex, 20, 32)
        }
    }

    private const val HEX = "0123456789abcdef"
}

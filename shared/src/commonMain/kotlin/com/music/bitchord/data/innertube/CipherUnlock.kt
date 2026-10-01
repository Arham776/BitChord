package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import kotlin.concurrent.Volatile

/**
 * Platform hook for YouTube player-JS work (signature timestamp +
 * signatureCipher unlock). Apple actual bridges to Swift/JSContext;
 * other platforms return null until wired.
 */
expect object CipherUnlock {
    suspend fun signatureTimestamp(): Int?
    suspend fun unlockCipher(videoId: String, cipher: String): String?
    suspend fun transformUrl(url: String): String?
}

/**
 * Whether this platform can solve signatures at all, as observed rather than
 * assumed.
 *
 * Recorded because the answer is not knowable up front — it depends on what
 * YouTube is serving and on whether this build's JS engine can parse it — and
 * because the two outcomes want opposite behaviour. A working solver means the
 * ciphered clients (ANDROID, [PlayerClient.WEB_REMIX]) are worth asking. A
 * broken one means they are not merely expensive but unusable, so
 * [StreamResolver] skips them rather than paying a signature solve to be told
 * the same thing for every already-failing track.
 *
 * A failure here is recorded, not repaired: re-fetching the player JavaScript
 * and parsing it again cannot end differently, because the parse failure is
 * deterministic for a given (extractor logic, player script) pair. It clears on
 * process restart, which is the right lifetime for "this deployment is
 * unreadable to us".
 */
object SignatureSolver {

    @Volatile
    private var broken = false

    val isBroken: Boolean get() = broken

    /** Called by the platform hook when a solve failed for a reason worth giving up on. */
    fun markBroken(cause: String) {
        if (broken) return
        broken = true
        DebugLog.w(
            "cannot read YouTube's current player JavaScript ($cause); ciphered formats are " +
                "unavailable for this process — signed-in device clients remain the route to an " +
                "age-restricted track",
        )
    }

    fun reset() {
        broken = false
    }
}

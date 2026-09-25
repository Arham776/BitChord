package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.concurrent.Volatile
import kotlin.coroutines.resume

/**
 * Apple actual: Swift registers [CipherUnlockBridge.Impl] at launch;
 * Kotlin suspends until the callback fires.
 */
actual object CipherUnlock {
    actual suspend fun signatureTimestamp(): Int? =
        CipherUnlockBridge.signatureTimestamp()

    actual suspend fun unlockCipher(videoId: String, cipher: String): String? =
        CipherUnlockBridge.unlockCipher(videoId, cipher)
}

/**
 * Swift-facing registration surface (stable ObjC name for the app to call).
 */
object CipherUnlockBridge {

    interface Impl {
        fun signatureTimestamp(callback: ResultCallback)
        fun unlockCipher(videoId: String, cipher: String, callback: ResultCallback)
    }

    fun interface ResultCallback {
        fun onResult(value: String?, error: String?)
    }

    @Volatile
    private var impl: Impl? = null

    fun setImpl(value: Impl?) {
        impl = value
    }

    suspend fun signatureTimestamp(): Int? {
        val bridge = impl ?: return null
        val raw = suspendCancellableCoroutine { cont ->
            bridge.signatureTimestamp(ResultCallback { value, _ ->
                if (cont.isActive) cont.resume(value)
            })
        }
        return raw?.toIntOrNull()
    }

    suspend fun unlockCipher(videoId: String, cipher: String): String? {
        val bridge = impl ?: return null
        return suspendCancellableCoroutine { cont ->
            bridge.unlockCipher(videoId, cipher, ResultCallback { value, error ->
                if (error != null) {
                    // A failure this broad is a player JavaScript this build
                    // cannot parse, which no retry will fix — see
                    // [SignatureSolver] for why it is recorded rather than
                    // re-attempted.
                    if (error.isUnparseablePlayer()) SignatureSolver.markBroken(error)
                    DebugLog.d("cipher unlock failed: $error")
                }
                if (cont.isActive) cont.resume(value)
            })
        }
    }

    /**
     * Whether the error says this build could not *read* the player script,
     * as opposed to having failed one particular signature.
     *
     * Matched on named phrases rather than broadly on "parse" on purpose: the
     * cost of a false positive is that every ciphered client is written off for
     * the rest of the process, which would trade one track's failure for a
     * session's.
     */
    private fun String.isUnparseablePlayer(): Boolean {
        val text = lowercase()
        return "deobfuscation function" in text ||
            "player js" in text ||
            "player javascript" in text ||
            "javascript base url" in text ||
            "not found in base.js" in text ||
            "function" in text && "not found" in text
    }
}

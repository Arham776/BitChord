package com.music.bitchord.data.innertube

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
                    println("[CipherUnlock] $error")
                }
                if (cont.isActive) cont.resume(value)
            })
        }
    }
}

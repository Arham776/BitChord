package com.music.bitchord.data.innertube

/**
 * Platform hook for YouTube player-JS work (signature timestamp +
 * signatureCipher unlock). Apple actual bridges to Swift/JSContext;
 * other platforms return null until wired.
 */
expect object CipherUnlock {
    suspend fun signatureTimestamp(): Int?
    suspend fun unlockCipher(videoId: String, cipher: String): String?
}

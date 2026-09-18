package com.music.bitchord.data.lyrics

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.writeToFile
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fread
import kotlin.math.min

@OptIn(ExperimentalForeignApi::class)
internal actual fun readFileHead(path: String, maxBytes: Int): ByteArray? {
    val file = fopen(path, "rb") ?: return null
    return try {
        val buf = ByteArray(maxBytes)
        val n = buf.usePinned { pinned ->
            fread(pinned.addressOf(0), 1.convert(), maxBytes.convert(), file).toInt()
        }
        when {
            n <= 0 -> ByteArray(0)
            n >= maxBytes -> buf
            else -> buf.copyOf(min(n, maxBytes))
        }
    } finally {
        fclose(file)
    }
}

@OptIn(ExperimentalForeignApi::class)
@Suppress("CAST_NEVER_SUCCEEDS")
internal actual fun writeUtf8File(path: String, text: String): Boolean {
    val ns = text as NSString
    return ns.writeToFile(path, atomically = true, encoding = NSUTF8StringEncoding, error = null)
}

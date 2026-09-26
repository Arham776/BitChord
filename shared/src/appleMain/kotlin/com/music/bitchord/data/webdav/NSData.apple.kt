package com.music.bitchord.data.webdav

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSMutableData
import platform.posix.memcpy

/**
 * A copy of these bytes as Foundation's immutable buffer.
 *
 * `NSMutableData` plus `memcpy` rather than `dataWithBytes:length:`, because the
 * cinterop surface of Foundation on this platform does not expose the factory — and
 * `setLength` is the one that does. The copy is what makes it safe to hand out: the
 * `NSData` owns its bytes, so nothing here can change under a view that is drawing.
 */
@OptIn(ExperimentalForeignApi::class)
internal fun ByteArray.asNSData(): NSData {
    val data = NSMutableData()
    if (isEmpty()) return data
    data.setLength(size.convert())
    usePinned { pinned -> memcpy(data.mutableBytes, pinned.addressOf(0), size.convert()) }
    return data
}

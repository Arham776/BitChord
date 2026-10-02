@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.metrolist.innertubex.cipher

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import platform.Foundation.NSThread
import kotlin.coroutines.CoroutineContext

internal actual fun appleCipherDispatcher(): CoroutineDispatcher = object : CoroutineDispatcher() {
    private val tasks = Channel<Runnable>(Channel.UNLIMITED)
    private val thread = NSThread {
        runBlocking { for (task in tasks) task.run() }
    }.apply {
        name = "BitChord-YouTube-JS"
        // iOS worker threads default to 512 KiB: a 512 KiB QuickJS budget could
        // reach the guard page before its check. Leave ample host/Kotlin margin.
        stackSize = (4 * 1024 * 1024).toULong()
        start()
    }
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        check(tasks.trySend(block).isSuccess)
    }
}

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.metrolist.innertubex.cipher

import platform.JavaScriptCore.JSContext

/** One isolated JavaScriptCore VM, confined to the app's dedicated cipher thread. */
internal actual class AppleJavascriptRuntime actual constructor() {
    private var context: JSContext? = null
    actual fun initialize() { if (context == null) context = JSContext() }
    actual fun evaluate(code: String): String? {
        val runtime = checkNotNull(context) { "JavaScript runtime unavailable" }
        runtime.exception = null
        val value = runtime.evaluateScript(code)
        val failure = runtime.exception
        if (failure != null) {
            runtime.exception = null
            // Never export the remote script, arguments, or stack trace.
            throw IllegalStateException("Apple JavaScript evaluation failed")
        }
        return if (value == null || value.isNull || value.isUndefined) null else value.toString()
    }
    actual fun close() { context = null }
}

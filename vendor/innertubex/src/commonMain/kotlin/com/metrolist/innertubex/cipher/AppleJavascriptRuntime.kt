package com.metrolist.innertubex.cipher

/** Platform runtime only; upstream's EJS parser and extraction stay unchanged. */
internal expect class AppleJavascriptRuntime() {
    fun initialize()
    fun evaluate(code: String): String?
    fun close()
}

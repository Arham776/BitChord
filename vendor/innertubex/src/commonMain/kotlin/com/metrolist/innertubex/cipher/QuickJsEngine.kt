package com.metrolist.innertubex.cipher

import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Upstream EJS execution facade backed by Apple's JavaScriptCore on Apple platforms. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
internal class QuickJsEngine {
    companion object {
        // A single OS thread owns each JavaScript context throughout its lifetime.
        private val jsDispatcher by lazy { appleCipherDispatcher() }
        private const val MAX_EVALUATION_RESULT_LENGTH = 16 * 1024 * 1024
        private const val MAX_FUNCTION_INPUT_LENGTH = 64 * 1024
        private const val MAX_FUNCTION_RESULT_LENGTH = 256 * 1024
        private val JS_IDENTIFIER = Regex("[A-Za-z_$][A-Za-z0-9_$]*")

        /** Valid JavaScript double-quoted string literal for passing into evaluated calls. */
        internal fun jsStringLiteral(s: String): String =
            buildString(s.length + 2) {
                append('"')
                for (c in s) {
                    when (c) {
                        '\\' -> {
                            append("\\\\")
                        }

                        '"' -> {
                            append("\\\"")
                        }

                        '\n' -> {
                            append("\\n")
                        }

                        '\r' -> {
                            append("\\r")
                        }

                        '\t' -> {
                            append("\\t")
                        }

                        else -> {
                            if (c.code < 0x20) {
                                val hex = c.code.toString(16).padStart(4, '0')
                                append("\\u$hex")
                            } else {
                                append(c)
                            }
                        }
                    }
                }
                append('"')
            }
    }

    private val mutex = Mutex()
    private var quickJs: AppleJavascriptRuntime? = null

    /**
     * Initialize the Apple JavaScript runtime.
     */
    suspend fun initialize() =
        withContext(jsDispatcher) {
            mutex.withLock {
                if (quickJs == null) {
                    quickJs = AppleJavascriptRuntime().also { it.initialize() }
                }
            }
        }

    /**
     * Execute JavaScript code and return the result.
     *
     * @param code The JavaScript code to execute
     * @param collectGarbage Retained for compatibility; JavaScriptCore manages collection.
     * @return The result of the execution as a string
     */
    suspend fun evaluate(
        code: String,
        maxResultLength: Int,
        collectGarbage: Boolean = false,
    ): String =
        withContext(jsDispatcher) {
            require(maxResultLength in 1..MAX_EVALUATION_RESULT_LENGTH) { "Invalid QuickJS result limit" }
            mutex.withLock {
                val runtime = quickJs ?: throw IllegalStateException("JavaScript runtime not initialized")
                val boundedCode =
                    """
                    (function() {
                      const value = ($code);
                      if (value == null) return "";
                      const text = String(value);
                      return text.length <= $maxResultLength ? text : "";
                    })()
                    """
                runtime.evaluate(boundedCode).orEmpty()
            }
        }

    /** Execute JavaScript for side effects without marshalling the final value. */
    suspend fun execute(code: String) {
        withContext(jsDispatcher) {
            mutex.withLock {
                val runtime = quickJs ?: throw IllegalStateException("JavaScript runtime not initialized")
                runtime.evaluate("$code\n;undefined;")
            }
        }
    }

    /**
     * Execute a JavaScript function with parameters.
     *
     * @param functionName The name of the function to call
     * @param input The string parameter to pass to the function
     * @return The bounded string result, or null when the input or result is too large
     */
    suspend fun callFunction(
        functionName: String,
        input: String,
    ): String? =
        withContext(jsDispatcher) {
            require(JS_IDENTIFIER.matches(functionName)) { "Invalid JavaScript function name" }
            if (input.length > MAX_FUNCTION_INPUT_LENGTH) return@withContext null
            mutex.withLock {
                val runtime = quickJs ?: throw IllegalStateException("JavaScript runtime not initialized")
                val inputLiteral = jsStringLiteral(input)
                runtime.evaluate(
                    """
                    (function() {
                      const value = $functionName($inputLiteral);
                      if (value == null) return null;
                      const text = String(value);
                      return text.length <= $MAX_FUNCTION_RESULT_LENGTH ? text : null;
                    })()
                    """.trimIndent(),
                )
            }
        }

    /**
     * Set up the global environment for YouTube player execution.
     * This creates necessary globals like XMLHttpRequest, URL, location, etc.
     */
    suspend fun setupYoutubeGlobals() =
        withContext(jsDispatcher) {
            val setupCode =
                """
                if (typeof globalThis.XMLHttpRequest === "undefined") {
                    globalThis.XMLHttpRequest = { prototype: {} };
                }
                if (typeof URL === "undefined") {
                    globalThis.location = {
                        hash: "",
                        host: "www.youtube.com",
                        hostname: "www.youtube.com",
                        href: "https://www.youtube.com/watch?v=yt-dlp-wins",
                        origin: "https://www.youtube.com",
                        password: "",
                        pathname: "/watch",
                        port: "",
                        protocol: "https:",
                        search: "?v=yt-dlp-wins",
                        username: "",
                    };
                } else {
                    globalThis.location = new URL("https://www.youtube.com/watch?v=yt-dlp-wins");
                }
                if (typeof globalThis.document === "undefined") {
                    globalThis.document = Object.create(null);
                }
                if (typeof globalThis.navigator === "undefined") {
                    globalThis.navigator = Object.create(null);
                }
                if (typeof globalThis.self === "undefined") {
                    globalThis.self = globalThis;
                }
                if (typeof globalThis.window === "undefined") {
                    globalThis.window = globalThis;
                }
                if (typeof globalThis.Intl === "undefined") {
                    const NumberFormat = function(locale, options) {
                        this.options = options || {};
                    };
                    NumberFormat.supportedLocalesOf = function(locales) {
                        return Array.isArray(locales) ? locales : [locales];
                    };
                    NumberFormat.prototype.format = function(value) {
                        let formatted = String(value);
                        const minimumDigits = this.options.minimumIntegerDigits || 0;
                        while (formatted.length < minimumDigits) formatted = "0" + formatted;
                        return formatted;
                    };
                    const DateTimeFormat = function() {};
                    DateTimeFormat.prototype.resolvedOptions = function() {
                        return { timeZone: "UTC" };
                    };
                    DateTimeFormat.prototype.format = function(value) {
                        return String(value);
                    };
                    globalThis.Intl = { NumberFormat, DateTimeFormat };
                }
                """.trimIndent()

            execute(setupCode)
        }

    /**
     * Load the YouTube player JavaScript code into the engine.
     *
     * @param playerCode The YouTube player JavaScript code
     */
    suspend fun loadPlayerScript(playerCode: String) =
        withContext(jsDispatcher) {
            // First setup globals
            setupYoutubeGlobals()

            // Then load the player code
            execute(playerCode)
        }

    /**
     * Clean up and release resources.
     */
    suspend fun dispose() =
        withContext(jsDispatcher) {
            mutex.withLock {
                quickJs?.close()
                quickJs = null
            }
        }
}

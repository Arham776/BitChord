package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import platform.Foundation.NSMutableData
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import platform.Foundation.writeToFile
import platform.posix.FILE
import platform.posix.fclose
import platform.posix.fflush
import platform.posix.fopen
import platform.posix.fwrite

/**
 * Swift-facing bridge for downloading audio streams.
 *
 * Goes through [Http.getBytes], so the media fetch shares its connection context
 * with the `player` request that minted the URL and with the probe that cleared
 * it. That is upstream's rule and the reason [Http] is one client:
 *
 *  > googlevideo binds a stream URL to the connection context of the `player`
 *  > request that minted it. If Innertube and the media fetch used separate HTTP
 *  > stacks they could resolve to different addresses (v4 vs v6) and the media
 *  > fetch would come back 403.
 *
 * (An earlier version ran a client of its own, on the theory that URLSession has
 * a different TLS fingerprint from Ktor's Darwin engine. That was a symptom of
 * the split, not a cause of it — and with one client there is no longer a second
 * fingerprint to differ.)
 *
 * Upstream's ExoPlayer starts as soon as the first bounded range arrives, and
 * [streamToFile] matches that: the first chunk is on disk and [ready] fires so
 * the engine can play while later chunks keep appending.
 */
object StreamDownloadBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface DownloadCallback {
        fun onResult(path: String?, message: String?)
    }

    /** Wait for the whole file, then [callback]. Prefetch / cache path. */
    fun download(url: String, headers: Map<String, String>, callback: DownloadCallback) {
        streamToFile(url, headers, ready = DownloadCallback { _, _ -> }, done = callback)
    }

    /**
     * Progressive fetch. [ready] fires once the first chunk is on disk, so play can
     * start; [done] fires when the last chunk is written, or on error.
     *
     * The chunk size is [CHUNK_BYTES] — the same figure [Http.probe] asks for, and
     * deliberately so: a probe smaller than the real fetch cannot see a refusal the
     * real fetch would meet. This was 1 MiB against a 16 KiB probe, which meant a
     * URL willing to serve a token range sailed through the probe and then died on
     * the playback path.
     *
     * A 403 on a chunk is reported to [StreamResolver.onPlaybackRefused] rather
     * than retried blindly. Retrying the same URL against the same client is how a
     * session talks itself into being throttled, and the resolver already knows how
     * to forget the URL and stand the client down — which is the response that
     * actually changes the next attempt.
     */
    @OptIn(ExperimentalForeignApi::class)
    fun streamToFile(
        url: String,
        headers: Map<String, String>,
        ready: DownloadCallback,
        done: DownloadCallback,
    ) {
        bridgeScope.launch {
            var tmpPath: String? = null
            var file: CPointer<FILE>? = null
            try {
                DebugLog.d("stream starting: ${url.take(120)}")

                val chunkSize = CHUNK_BYTES
                val tmpDir = NSTemporaryDirectory()
                val ext = when {
                    url.contains("mime=video", ignoreCase = true) ||
                        url.contains("itag=18") -> "mp4"
                    else -> "m4a"
                }
                val path = "$tmpDir/bitchord-${NSUUID().UUIDString}.$ext"
                tmpPath = path

                // Upstream reads the total out of the URL's own `clen` rather than
                // making a request to find out, so read-ahead knows when it is done.
                clenFromUrl(url)?.let { clen ->
                    val lenPath = "$path.len"
                    val digits = clen.toString().encodeToByteArray()
                    val lenFile = fopen(lenPath, "wb")
                    if (lenFile != null) {
                        digits.usePinned { pinned ->
                            fwrite(
                                pinned.addressOf(0),
                                1.convert(),
                                digits.size.convert(),
                                lenFile,
                            )
                        }
                        fclose(lenFile)
                    }
                }
                NSMutableData().writeToFile("$path.grow", atomically = true)

                var offset = 0L
                var consecutiveEmpty = 0
                var readyFired = false

                while (true) {
                    val rangeEnd = offset + chunkSize - 1
                    val rangeHeaders = headers + ("Range" to "bytes=$offset-$rangeEnd")

                    val data = try {
                        Http.getBytes(url, rangeHeaders)
                    } catch (e: Throwable) {
                        val code = httpCodeOf(e)
                        if (code != null && code in REFUSAL_CODES) {
                            DebugLog.w("stream refused with $code at offset $offset")
                            StreamResolver.onPlaybackRefused(url, code)
                        } else {
                            DebugLog.w("stream chunk failed at offset $offset: ${e.message}")
                        }
                        throw e
                    }

                    if (data.isEmpty()) {
                        consecutiveEmpty++
                        DebugLog.d("stream returned an empty chunk ($consecutiveEmpty), stopping")
                        if (consecutiveEmpty >= 2) break
                        continue
                    }
                    consecutiveEmpty = 0

                    if (file == null) {
                        file = fopen(path, "wb")
                            ?: throw IllegalStateException("open $path failed")
                    }
                    data.usePinned { pinned ->
                        val written = fwrite(
                            pinned.addressOf(0),
                            1.convert(),
                            data.size.convert(),
                            file,
                        )
                        if (written.toLong() != data.size.toLong()) {
                            throw IllegalStateException("short write at offset $offset")
                        }
                    }
                    fflush(file)
                    offset += data.size

                    if (!readyFired) {
                        readyFired = true
                        DebugLog.d("first chunk ready: $path ($offset bytes)")
                        ready.onResult(path, null)
                    }

                    if (data.size < chunkSize) break
                    if (offset > MAX_BYTES) break
                }

                file?.let { fflush(it); fclose(it) }
                file = null

                if (!readyFired) {
                    done.onResult(null, "Download returned no bytes")
                    return@launch
                }

                NSMutableData().writeToFile("$path.complete", atomically = true)
                DebugLog.d("stream complete: $path ($offset bytes)")
                done.onResult(path, null)
            } catch (e: Throwable) {
                DebugLog.e("stream failed", e)
                // Marked complete either way: a half-written file left looking
                // unfinished would be re-read forever by the growing-file reader.
                tmpPath?.let { NSMutableData().writeToFile("$it.complete", atomically = true) }
                done.onResult(null, e.message ?: e.toString())
            } finally {
                file?.let { fclose(it) }
            }
        }
    }

    /** The status code out of [Http]'s refusal message, if it was a refusal. */
    private fun httpCodeOf(e: Throwable): Int? =
        e.message?.let { message ->
            Regex("HTTP (\\d{3})").find(message)?.groupValues?.get(1)?.toIntOrNull()
        }

    private val REFUSAL_CODES = setOf(403, 404, 410)

    /**
     * Two megabytes, matching [Http.probe]. Upstream's `ChunkedDataSource` and
     * `AudioCache` both fetch ranges of this size, and the probe has to test the
     * request that matters rather than a smaller, more forgiving one.
     */
    private const val CHUNK_BYTES = 2L * 1024 * 1024

    /** A ceiling so a URL that never stops returning data cannot fill the disk. */
    private const val MAX_BYTES = 200L * 1024 * 1024
}

private fun clenFromUrl(url: String): Long? {
    val query = url.substringAfter('?', missingDelimiterValue = "")
    if (query.isEmpty()) return null
    for (part in query.split('&')) {
        val eq = part.indexOf('=')
        if (eq > 0 && part.substring(0, eq) == "clen") {
            return part.substring(eq + 1).substringBefore('&').toLongOrNull()
        }
    }
    return null
}

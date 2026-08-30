package com.music.bitchord.data.innertube

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
 * Swift-facing bridge for downloading audio streams via Ktor's Darwin engine.
 * URLSession gets 403 from googlevideo (different TLS fingerprint), but Ktor's
 * Darwin engine has the same fingerprint as the probe that succeeds.
 *
 * Upstream ExoPlayer starts as soon as the first bounded range arrives.
 * [streamToFile] matches that: the first 1 MiB is on disk and [ready] fires
 * so the engine can probe/play while later ranges keep appending.
 */
object StreamDownloadBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface DownloadCallback {
        fun onResult(path: String?, message: String?)
    }

    /**
     * Wait for the whole file, then [callback]. Prefetch / cache path.
     */
    fun download(url: String, headers: Map<String, String>, callback: DownloadCallback) {
        streamToFile(url, headers, ready = DownloadCallback { _, _ -> }, done = callback)
    }

    /**
     * Progressive fetch. [ready] fires once the first range is on disk (play
     * can start). [done] fires when the last range is written, or on error.
     *
     * Chunk size is 1 MiB (not upstream's 2 MiB) because some networks refuse
     * a first range larger than 1 MiB.
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
                println("[StreamDownload] Starting download: ${url.take(120)}...")

                val chunkSize = 1 * 1024 * 1024L
                val tmpDir = NSTemporaryDirectory()
                val ext = when {
                    url.contains("mime=video", ignoreCase = true) ||
                        url.contains("itag=18") -> "mp4"
                    else -> "m4a"
                }
                val path = "$tmpDir/bitchord-${NSUUID().UUIDString}.$ext"
                tmpPath = path

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

                    println("[StreamDownload] Fetching chunk: bytes=$offset-$rangeEnd")
                    var chunkData: ByteArray? = null
                    var lastErr: Throwable? = null
                    for (attempt in 0..1) {
                        try {
                            chunkData = Http.getBytes(url, rangeHeaders)
                            lastErr = null
                            break
                        } catch (e: Throwable) {
                            lastErr = e
                            println("[StreamDownload] getBytes attempt ${attempt + 1} failed: ${e.message}")
                            if (e.message?.contains("403") == true && attempt == 0) {
                                kotlinx.coroutines.delay(800)
                                continue
                            } else break
                        }
                    }
                    if (lastErr != null) throw lastErr
                    val data = chunkData!!
                    println("[StreamDownload] Got chunk: ${data.size} bytes status ok")

                    if (data.isEmpty()) {
                        consecutiveEmpty++
                        println("[StreamDownload] Empty chunk $consecutiveEmpty, stopping")
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
                        println("[StreamDownload] First chunk ready: $path ($offset bytes)")
                        ready.onResult(path, null)
                    }

                    if (data.size < chunkSize) {
                        println("[StreamDownload] Last chunk received (total $offset)")
                        break
                    }
                    if (offset > 200 * 1024 * 1024) {
                        println("[StreamDownload] Safety cap hit")
                        break
                    }
                }

                file?.let { fflush(it); fclose(it) }
                file = null

                if (!readyFired) {
                    done.onResult(null, "Download returned no bytes (googlevideo 403? n-param?)")
                    return@launch
                }

                NSMutableData().writeToFile("$path.complete", atomically = true)
                println("[StreamDownload] Download complete: $path ($offset bytes)")
                done.onResult(path, null)
            } catch (e: Throwable) {
                println("[StreamDownload] Error: ${e.message}")
                e.printStackTrace()
                tmpPath?.let { p ->
                    NSMutableData().writeToFile("$p.complete", atomically = true)
                }
                done.onResult(null, e.message ?: e.toString())
            } finally {
                file?.let { fclose(it) }
            }
        }
    }
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

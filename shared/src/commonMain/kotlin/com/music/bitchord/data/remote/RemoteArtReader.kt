package com.music.bitchord.data.remote

import com.music.bitchord.data.http.Http

/**
 * [EmbeddedArt] backends: somewhere to read a remote file's front from.
 *
 * Port of upstream `data/remote/RemoteArtReader.kt`, minus its SMB half — see the note
 * at the bottom of this file for why that is not a gap to be filled later.
 *
 * The reader stays a dumb byte fetcher. All the format knowledge is in
 * [EmbeddedArt], so a new container is a change in one file rather than in every
 * backend.
 */
object RemoteArtReader {

    /**
     * A reader over HTTP byte ranges, for a file addressed by URL.
     *
     * Through the shared [Http] client, so the request this makes is the same request
     * playback makes — same TLS stack, same connection pool, same cookies.
     *
     * The two statuses this has to tell apart:
     *
     * - **`206`** — the range was honoured, and the body starts at [offset].
     * - **`200`** — the range was ignored and the whole file is on its way. Then only
     *   the front is usable, because everything this returns has to be anchored at
     *   [offset] and a body anchored at zero is not. The read is still bounded (see
     *   [Http.getBytesRaw]) so "this server does not do ranges" costs a few kilobytes
     *   rather than a download per track, and a cover at the front of the file is
     *   still found — which is where every cover in a tagged file is.
     *
     * @param authHeader the share's `Authorization` header, or null for an open one.
     *   Passed in rather than read from a global because the credential is a settings
     *   value on this platform, and a process-wide cache of it would outlive the
     *   settings screen that set it.
     */
    fun http(url: String, authHeader: String? = null): EmbeddedArt.Reader = object : EmbeddedArt.Reader {
        // A ranged read does not learn the file's length, and asking separately would
        // be a second round trip on every file. `UNKNOWN_SIZE` is what the cursors
        // already treat as "ask for a window and see what comes".
        override val size: Long = EmbeddedArt.UNKNOWN_SIZE

        override suspend fun read(offset: Long, length: Int): ByteArray {
            if (length <= 0 || offset < 0) return ByteArray(0)
            val headers = buildMap {
                if (authHeader != null) put("Authorization", authHeader)
                put("Range", "bytes=$offset-${offset + length - 1}")
            }
            val response = Http.getBytesRaw(url, headers, maxBytes = length)
            val body = response.body ?: return ByteArray(0)
            return when (response.status) {
                // Honoured. A server that sent less than asked for is within its
                // rights, and the parsers all cope with a short read.
                206 -> body.take(length).toByteArray()
                // Ignored: the body is the file from byte zero, so it is only usable
                // for a read that wanted the front. `Http` has already cut it to
                // `length` bytes, so taking it as it stands cannot pull a whole file
                // into memory here.
                200 -> if (offset == 0L) body else ByteArray(0)
                // Asked for bytes past the end: the end of the file, not a failure.
                416 -> ByteArray(0)
                else -> throw WebDavException("Range read failed with ${response.status}")
            }
        }
    }

    /**
     * The picture inside the file at [url], or null when it has none.
     *
     * Never throws. A cover is decoration for a row, and a row whose decoration
     * failed is still a row — the alternative is a remote library that refuses to draw
     * because one file is encrypted, truncated or tagged in a dialect nothing here
     * knows.
     */
    suspend fun picture(url: String, authHeader: String? = null): EmbeddedArt.Picture? =
        EmbeddedArt.extract(http(url, authHeader))
}

/*
 * No SMB backend, deliberately.
 *
 * Upstream's reads an `smb://` URL through `smbj`, which is a JVM library: no
 * Objective-C runtime, no Kotlin/Native klib, no way to run it on Darwin without a
 * JNI-equivalent this platform does not have. Adding SMB would mean shipping a Java
 * runtime in the app, which is a worse answer than not having the feature.
 *
 * The platform has its own answer, and it is the one a Mac or an iPad user already
 * has: a share mounted by the file system (Finder's Connect To Server, or the Files
 * app) is a local library as far as this app is concerned, and a local library is
 * already implemented. SMB is therefore a *file system* question on Apple rather
 * than a networking one, and the honest thing is to leave it to the platform rather
 * than to reimplement a network protocol badly.
 */

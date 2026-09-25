package com.music.bitchord.data.innertube

/**
 * Port of upstream `data/innertube/PlayerClient.kt` — one client identity for
 * the `player` endpoint.
 *
 * Three things travel together and must not be separated: [userAgent] (which
 * the media fetch should repeat — googlevideo bakes the client into the URL
 * as `c=`/`cver=` and compares), [origin] (browser-shaped clients only), and
 * the version, which is load-bearing: Google refuses a stale identity with a
 * bare HTTP 400 before playability is even considered. Versions checked
 * against the live endpoint as of July 2026, upstream's notes verbatim.
 *
 * The Apple port had dropped the two browser identities ([WEB_REMIX], [WEB]) on
 * the grounds that they return ciphered formats. That was half the story, and it
 * cost the signed-in path: [WEB_REMIX] is the one identity a *real* session
 * cookie is supposed to be attached to, and it is the fallback
 * [StreamResolver] reaches for once the anonymous device walk has been refused.
 * Without it, a bot check had nowhere to go — see [StreamResolver].
 *
 * Clients whose formats come back ciphered need YouTube's player JavaScript,
 * which is a platform hook rather than shared code ([CipherUnlock]); the
 * unciphered ones are a stream in a single POST.
 */
data class PlayerClient(
    val clientName: String,
    val clientVersion: String,
    val clientId: String,
    val userAgent: String,
    val osName: String? = null,
    val osVersion: String? = null,
    val deviceMake: String? = null,
    val deviceModel: String? = null,
    val androidSdkVersion: String? = null,
    /** The host this client runs on, for browser-shaped clients only. */
    val origin: String? = null,
    /**
     * Whether the player POST must carry `playbackContext.signatureTimestamp`
     * (sts from base.js). Required for clients whose formats come back
     * ciphered.
     */
    val needsSignatureTimestamp: Boolean = false,
) {
    val referer: String? get() = origin?.let { "$it/" }

    /**
     * Browser-shaped clients are served from the Music host; app clients from
     * YouTube proper. Not cosmetic: the `player` endpoint is hosted under both,
     * and a browser identity posted to the wrong one is refused.
     */
    val usesMusicHost: Boolean get() = origin == MUSIC_ORIGIN

    /** The base this client's `player` POST belongs on — see [usesMusicHost]. */
    val apiBase: String get() = if (usesMusicHost) MUSIC_BASE else YT_BASE

    /**
     * Headers the *media* request must carry for a URL this client minted.
     * The stream fetch is a separate request from the one that produced the
     * URL, and googlevideo treats a mismatch between the two as reason enough
     * to throttle the response to a crawl or refuse it with 403.
     */
    fun mediaHeaders(): Map<String, String> = buildMap {
        put("User-Agent", userAgent)
        origin?.let { put("Origin", it) }
        referer?.let { put("Referer", it) }
    }

    companion object {
        private const val MUSIC_ORIGIN = "https://music.youtube.com"
        private const val YOUTUBE_ORIGIN = "https://www.youtube.com"
        private const val MUSIC_BASE = "https://music.youtube.com/youtubei/v1"
        private const val YT_BASE = "https://www.youtube.com/youtubei/v1"

        private const val WEB_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

        /**
         * Phone YouTube app. Answers OK on flagged / CFNetwork sessions where
         * ANDROID_VR's adaptive URLs only serve the first megabyte then 403
         * (yt-dlp #17456, mid-2026). Formats are ciphered — needs sts + sig
         * unlock via [CipherUnlock].
         */
        val ANDROID = PlayerClient(
            clientName = "ANDROID",
            clientVersion = "21.26.364",
            clientId = "3",
            userAgent = "com.google.android.youtube/21.26.364 " +
                "(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip",
            osName = "Android",
            osVersion = "15",
            deviceMake = "Google",
            deviceModel = "Pixel 9 Pro",
            androidSdkVersion = "35",
            needsSignatureTimestamp = true,
        )

        /**
         * iPhone YouTube: answered without a login, without a proof of origin
         * token and without a signature timestamp, and it returns plain `url`
         * fields. The version is the whole ballgame — anything Google
         * considers stale is refused with an HTTP 400 before playability is
         * looked at.
         */
        val IOS = PlayerClient(
            clientName = "IOS",
            clientVersion = "21.26.4",
            clientId = "5",
            userAgent = "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            osName = "iPhone",
            osVersion = "18.3.2.22D82",
            deviceMake = "Apple",
            deviceModel = "iPhone16,2",
        )

        /** A newer build of the same app: refused on a different schedule. */
        val IOS_RECENT = IOS.copy(
            clientVersion = "21.29.1",
            userAgent = "com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)",
            osVersion = "18.5.22F70",
        )

        /**
         * YouTube Music Android app. Returns plain URLs without ciphering. As
         * of mid-2026 this client is not subject to the po_token enforcement
         * that blocks stream fetches from other clients — the only known
         * client that still serves HTTPS streams freely.
         */
        val ANDROID_MUSIC = PlayerClient(
            clientName = "ANDROID_MUSIC",
            clientVersion = "8.39.42",
            clientId = "21",
            userAgent = "com.google.android.apps.youtube.music/8.39.42 " +
                "(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip",
            osName = "Android",
            osVersion = "15",
            deviceMake = "Google",
            deviceModel = "Pixel 9 Pro",
            androidSdkVersion = "35",
        )

        /**
         * The Quest's YouTube app: unciphered, login-free, no proof-of-origin
         * token. Adaptive URLs from ≤1.65.10 now typically 403 after the first
         * megabyte on many networks (SABR migration) — kept as a last resort.
         */
        val ANDROID_VR = PlayerClient(
            clientName = "ANDROID_VR",
            clientVersion = "1.65.10",
            clientId = "28",
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 " +
                "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            osName = "Android",
            osVersion = "12L",
            deviceMake = "Oculus",
            deviceModel = "Quest 3",
            androidSdkVersion = "32",
        )

        /** An older build of the same app; refused on a different schedule. */
        val ANDROID_VR_LEGACY = ANDROID_VR.copy(
            clientVersion = "1.43.32",
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.43.32 " +
                "(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
        )

        /**
         * The browser identity music.youtube.com itself runs as.
         *
         * Not part of the anonymous walk — sent bare it is ciphered and refused
         * about as often as it works. What it is for is [StreamResolver]'s
         * signed-in retry: a session cookie is what a browser-shaped client is
         * *supposed* to carry, and Google answers a plausible one very
         * differently to a device client with none at all. This is the one
         * identity that is not an anonymous device pretending otherwise.
         *
         * Every format it returns is ciphered, so reaching it costs a signature
         * solve — which is why [StreamResolver] asks after the walk that returns
         * unciphered URLs, and skips it entirely when the solver is known broken.
         */
        val WEB_REMIX = PlayerClient(
            clientName = "WEB_REMIX",
            clientVersion = "1.20260707.12.00",
            clientId = "67",
            userAgent = WEB_USER_AGENT,
            origin = MUSIC_ORIGIN,
            needsSignatureTimestamp = true,
        )

        /**
         * YouTube proper's web client. A source of guest muxed audio, and the
         * identity a stream URL naming `WEB` has to be dressed as.
         */
        val WEB = PlayerClient(
            clientName = "WEB",
            clientVersion = "2.20260708.00.00",
            clientId = "1",
            userAgent = WEB_USER_AGENT,
            origin = YOUTUBE_ORIGIN,
        )

        /**
         * TV Cobalt v7 — the most reliable client for flagged IPs, and the one
         * that works on them without a PO Token. Uses cookie-based auth when a
         * session is available.
         */
        val TVHTML5 = PlayerClient(
            clientName = "TVHTML5",
            clientVersion = "7.20260707.07.00",
            clientId = "7",
            userAgent = "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 " +
                "(KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
            origin = YOUTUBE_ORIGIN,
        )

        /**
         * The client a googlevideo URL says minted it, so the media fetch can be
         * dressed as that client whatever produced the URL.
         *
         * Falls back to [IOS] when the URL names a client we don't model: it is
         * what mints most of them here, and being approximately right beats
         * sending a smart TV's headers for a URL an iPhone asked for.
         */
        fun forStreamUrl(url: String): PlayerClient {
            val name = url.queryParam("c")?.uppercase() ?: return IOS
            val version = url.queryParam("cver")
            return when {
                name.startsWith("IOS") ->
                    if (version == IOS_RECENT.clientVersion) IOS_RECENT else IOS
                name == "ANDROID_VR" ->
                    if (version == ANDROID_VR_LEGACY.clientVersion) ANDROID_VR_LEGACY else ANDROID_VR
                name == "ANDROID_MUSIC" -> ANDROID_MUSIC
                name.startsWith("ANDROID") -> ANDROID
                name.startsWith("TVHTML5") -> TVHTML5
                name == "WEB_REMIX" -> WEB_REMIX
                name.startsWith("WEB") || name == "MWEB" -> WEB
                else -> IOS
            }
        }

        /**
         * The largest single range googlevideo reliably serves for [url].
         *
         * Mirrors InnerTubeX's `mediaRangeChunkSize`, and it is *not* one number.
         * Two clients cap out at half what the others do: asking `ANDROID_VR` or a
         * `TVHTML5_SIMPLY` URL for a full megabyte range is answered with a 403,
         * because that is more than they will ever serve. Both the probe and the
         * real read have to respect it, and a probe that ignores it condemns a
         * working client on every single track — the probe asks for more than the
         * client will give, takes the refusal as evidence about the client, and
         * stands down something that was working.
         *
         * [Long.MAX_VALUE] for a non-googlevideo host: the limit is Google's, and
         * a module's or addon's own CDN is free to serve whatever it likes.
         */
        fun rangeBytesFor(url: String): Long {
            if (!url.contains("googlevideo.com")) return Long.MAX_VALUE
            val name = url.queryParam("c")?.uppercase() ?: return RANGE_BYTES
            return if (name == "ANDROID_VR" || name.startsWith("TVHTML5_SIMPLY")) {
                NARROW_RANGE_BYTES
            } else {
                RANGE_BYTES
            }
        }

        /**
         * How long [url] says the file is, which costs no request to read.
         *
         * Every progressive googlevideo URL carries it as `clen`. Null for the
         * URLs that do not — the extraction failsafe can produce one — and the
         * probe treats that as "unknown", asking its normal range rather than
         * assuming a length it has not been told.
         */
        fun lengthFromUrl(url: String): Long? = url.queryParamAsLong("clen")

        /**
         * A numeric query parameter of a googlevideo URL.
         *
         * No percent-decoding: these are bare digits, and the client and version
         * tokens are the ones that need it.
         */
        private fun String.queryParamAsLong(key: String): Long? {
            val query = substringAfter('?', "").takeIf { it.isNotEmpty() } ?: return null
            return query.split('&').firstNotNullOfOrNull { part ->
                val eq = part.indexOf('=')
                if (eq <= 0 || part.substring(0, eq) != key) return@firstNotNullOfOrNull null
                part.substring(eq + 1).toLongOrNull()
            }
        }

        /**
         * A query parameter of a googlevideo URL, percent-decoded.
         *
         * Hand-rolled because the alternative is a URL parser in common code, and
         * this is the only thing one is needed for here. Stops at the first `&`
         * and does not treat `+` as a space: these are base64-ish tokens, and
         * rewriting a `+` would corrupt one.
         */
        private fun String.queryParam(key: String): String? {
            val query = substringAfter('?', "").takeIf { it.isNotEmpty() } ?: return null
            return query.split('&').firstNotNullOfOrNull { part ->
                val eq = part.indexOf('=')
                if (eq <= 0 || part.substring(0, eq) != key) return@firstNotNullOfOrNull null
                decode(part.substring(eq + 1))
            }
        }

        private fun decode(value: String): String {
            if ('%' !in value) return value
            val out = StringBuilder(value.length)
            var i = 0
            while (i < value.length) {
                val c = value[i]
                if (c == '%' && i + 2 < value.length) {
                    val hex = value.substring(i + 1, i + 3).toIntOrNull(16)
                    if (hex != null) {
                        out.append(hex.toChar())
                        i += 3
                        continue
                    }
                }
                out.append(c)
                i++
            }
            return out.toString()
        }

        /** What a full-width client will serve in one range. */
        const val RANGE_BYTES = 1024L * 1024

        /** What `ANDROID_VR` and `TVHTML5_SIMPLY` will serve — half as much. */
        const val NARROW_RANGE_BYTES = 512L * 1024
    }
}

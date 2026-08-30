package com.music.bitchord.data.innertube

/**
 * Port of upstream `data/innertube/PlayerClient.kt` — one client identity for
 * the `player` endpoint, subset for the Apple app: only the identities that
 * answer with plain `url` fields. The ciphered clients (ANDROID, WEB_REMIX)
 * need YouTube's player JavaScript solved per track, which has no KMP
 * counterpart; every client here is a stream in one POST.
 *
 * Three things travel together and must not be separated: [userAgent] (which
 * the media fetch should repeat — googlevideo bakes the client into the URL
 * as `c=`/`cver=` and compares), [origin] (browser-shaped clients only), and
 * the version, which is load-bearing: Google refuses a stale identity with a
 * bare HTTP 400 before playability is even considered. Versions checked
 * against the live endpoint as of July 2026, upstream's notes verbatim.
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
     * (sts from base.js). Required for ANDROID / web clients whose formats
     * come back ciphered.
     */
    val needsSignatureTimestamp: Boolean = false,
) {
    val referer: String? get() = origin?.let { "$it/" }

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
        /**
         * Phone YouTube app. Answers OK on flagged / CFNetwork sessions where
         * ANDROID_VR's adaptive URLs only serve the first megabyte then 403
         * (yt-dlp #17456, mid-2026). Formats are ciphered — needs sts + sig
         * unlock via [CipherUnlockBridge].
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
         * Embedded web player — yt-dlp's remaining guest source of muxed
         * itag 18 (360p MP4 with AAC) when ANDROID adaptive is SABR-only.
         * Formats are typically ciphered; needs sts + sig unlock.
         */
        val WEB_EMBEDDED = PlayerClient(
            clientName = "WEB_EMBEDDED_PLAYER",
            clientVersion = "1.20260723.01.00",
            clientId = "56",
            userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
            origin = "https://www.youtube.com",
            needsSignatureTimestamp = true,
        )

        /**
         * TV Cobalt v7 — often works on OkHttp; under CFNetwork usually
         * answers "The page needs to be reloaded."
         */
        val TVHTML5 = PlayerClient(
            clientName = "TVHTML5",
            clientVersion = "7.20260707.07.00",
            clientId = "7",
            userAgent = "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 " +
                "(KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
            origin = "https://www.youtube.com",
        )
    }
}

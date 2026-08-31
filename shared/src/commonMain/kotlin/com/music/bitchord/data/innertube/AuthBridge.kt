package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.Http
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Swift-facing session seam. The cookie never sits in UserDefaults — Swift
 * keeps it in the Keychain and calls [applyCookie] on launch / after the
 * login WebView. Device-client `player` calls stay unsigned; only WEB_REMIX
 * browse/search/account carry the session (upstream Innertube.postPlayer).
 */
object AuthBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface DoneCallback {
        fun onResult(ok: Boolean, message: String?)
    }

    /** Same name-match as upstream [AuthStore.hasApiSid] — not a substring. */
    fun hasApiSid(cookieHeader: String): Boolean = Innertube.hasApiSid(cookieHeader)

    /**
     * Install or clear the in-memory session. Refuses a jar with no signing
     * secret so the app cannot report itself signed in while every request
     * stays anonymous.
     */
    fun applyCookie(cookieHeader: String?): Boolean {
        if (cookieHeader == null) {
            Innertube.cookie = null
            Http.installSessionCookies(null)
            return true
        }
        if (!Innertube.hasApiSid(cookieHeader)) return false
        Innertube.cookie = cookieHeader
        Http.installSessionCookies(cookieHeader)
        return true
    }

    fun isSignedIn(): Boolean = Innertube.cookie?.let { Innertube.hasApiSid(it) } == true

    /** Resolve which Google account the cookie acts as, before Home/library. */
    fun ensureSession(callback: DoneCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                callback.onResult(true, null)
            } catch (e: Throwable) {
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }
}

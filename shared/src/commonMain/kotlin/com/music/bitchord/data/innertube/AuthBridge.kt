package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Swift-facing session seam.
 *
 * The cookie itself is kept by the host — the Keychain via [AuthStore] on Apple,
 * where the equivalent of upstream's `EncryptedSharedPreferences` is the
 * Keychain rather than `UserDefaults` — and reaches Innertube only through
 * [applyCookie], which refuses a jar with no signing secret so the app cannot
 * report itself signed in while every request stays anonymous.
 *
 * The cookie travels as a request **header**, exactly as upstream sends it. It is
 * deliberately *not* mirrored into an `HTTPCookieStorage`: a jar is domain-scoped
 * so it could never protect the media fetch from it anyway, and mirroring it would
 * have put two `Cookie` headers on every signed-in request. See the note on
 * `Http` for the whole argument.
 *
 * Applying a session also clears the resolver's memory. Every "this track cannot be
 * played" and every "this identity is not being served" it recorded was recorded
 * under different rules — an age gate is the one verdict a session overturns, and a
 * client refused while anonymous is owed a fresh hearing now that there is a cookie
 * to send — so without this a listener who signs in specifically to play a track is
 * told for ten minutes that it still cannot be played. Same in reverse on sign-out.
 */
object AuthBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface DoneCallback {
        fun onResult(ok: Boolean, message: String?)
    }

    fun interface IdentityCallback {
        fun onResult(pageId: String?, dataSyncId: String?, authUser: String?)
    }

    /**
     * The YouTube identity this session is acting as, once it has settled on one.
     *
     * Answered as three strings rather than a record because "not settled yet" is
     * the common answer for the first second or so of a launch, and null is how
     * that says so. A caller building the listen-as list wants the *default*
     * channel — the one requests are already being sent as — and has nowhere else
     * to get it: the full channel listing is a different call upstream makes, and
     * a caller that guessed would be guessing.
     */
    fun currentIdentity(callback: IdentityCallback) {
        bridgeScope.launch {
            runCatching { Innertube.ensureSessionScope() }
            val identity = Innertube.currentIdentity()
            callback.onResult(identity?.pageId, identity?.dataSyncId, identity?.authUser)
        }
    }

    /** Same name-match as upstream `AuthStore.hasApiSid` — not a substring. */
    fun hasApiSid(cookieHeader: String): Boolean = Innertube.hasApiSid(cookieHeader)

    /**
     * Install or clear the in-memory session.
     *
     * @return false for a jar with no signing secret, which is refused rather than
     *   stored: accepting it would declare the app signed in while every request
     *   went out unsigned, and Google answers a request from nobody as a stranger.
     */
    fun applyCookie(cookieHeader: String?): Boolean {
        if (cookieHeader == null) {
            Innertube.cookie = null
            StreamResolver.onSessionChanged()
            return true
        }
        if (!Innertube.hasApiSid(cookieHeader)) {
            DebugLog.w("refusing a session cookie with no SAPISID signing secret")
            return false
        }
        Innertube.cookie = cookieHeader
        StreamResolver.onSessionChanged()
        return true
    }

    fun isSignedIn(): Boolean = Innertube.cookie?.let { Innertube.hasApiSid(it) } == true

    /**
     * Resolve which Google account the cookie acts as, and read the live WEB_REMIX
     * version out of the shell.
     *
     * Worth doing before anything that depends on being the right account rather than
     * on demand: a play registered under the wrong account is indistinguishable, to
     * the listener, from one that was never registered at all, and a client version
     * Google has never shipped is a standing invitation to be treated as something
     * other than a music client.
     */
    fun ensureSession(callback: DoneCallback) {
        bridgeScope.launch {
            try {
                Innertube.ensureSessionScope()
                callback.onResult(true, null)
            } catch (e: Throwable) {
                DebugLog.e("could not read the session scope", e)
                callback.onResult(false, e.message ?: e.toString())
            }
        }
    }
}

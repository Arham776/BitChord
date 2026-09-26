package com.music.bitchord.data.webdav

import com.music.bitchord.data.remote.WebDavConfig
import com.music.bitchord.data.settings.AppSettings

/**
 * Which requests may carry this device's WebDAV credential, and what it is.
 *
 * Port of upstream `data/webdav/WebDavAuth.kt`, minus the OkHttp interceptor and plus
 * the reason the interceptor is not needed here.
 *
 * Upstream publishes the host and the header into process-wide state, and
 * `Http`'s interceptor reads them on every outgoing request, so a `PROPFIND`, a cover
 * fetch and a playback range all pick the credential up without asking. This port's
 * [com.music.bitchord.data.http.Http] is a seam with a per-call header map and no
 * interceptor, so the header is passed explicitly — which is why the decision of
 * *which* requests deserve it lives in one place and is asked for by name.
 *
 * ## The rule, and why it is the whole point of this object
 *
 * A credential goes to the host it belongs to and nowhere else. A WebDAV listing is
 * attacker-shaped data in the sense that matters here: the server decides which hosts
 * appear in the `href`s it hands back, and one absolute `href` on another host is
 * enough to make a client send `Authorization: Basic` — a base64 string, i.e. the
 * password in the clear — to a host the listener has never heard of. Upstream is right
 * about this and gets it right by the host, not by the port; see [headerFor].
 *
 * Reading the settings rather than being handed them means the answer cannot go stale:
 * there is no sequence of calls that leaves the published header disagreeing with what
 * the settings screen shows.
 */
object WebDavAuth {

    /** The credential for [requestUrl], or null when it is not ours to send. */
    fun headerFor(requestUrl: String): String? {
        val configured = AppSettings.webDavUrl.value
        if (!WebDavConfig.isConfigured(configured)) return null
        val host = WebDavConfig.hostOf(requestUrl) ?: return null
        // Host-only comparison, and that is [WebDavConfig.hostOf]'s own rule rather than
        // an accident: a share on `example.com:8443` has to get the credential that
        // belongs to `example.com`, and matching on the port as well would both send a
        // secret to a host it does not belong to and withhold it from the one it does.
        if (host != WebDavConfig.hostOf(configured)) return null
        return WebDavConfig.basicAuthHeader(
            AppSettings.webDavUsername.value,
            AppSettings.webDavPassword.value,
        )
    }

    /** Whether a request to [requestUrl] would be given the credential. */
    fun authorizes(requestUrl: String): Boolean = headerFor(requestUrl) != null

    /** Whether there is a share configured at all. */
    fun isConfigured(): Boolean = WebDavRepository.isConfigured()
}

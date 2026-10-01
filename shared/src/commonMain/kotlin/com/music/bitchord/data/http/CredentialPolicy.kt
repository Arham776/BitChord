package com.music.bitchord.data.http

import io.ktor.http.Url

/** Scheme/host/port form a credential boundary, including on redirects. */
object CredentialPolicy {
    fun sameOrigin(first: String, second: String): Boolean = runCatching {
        val a = Url(first); val b = Url(second)
        a.protocol == b.protocol && a.host.equals(b.host, ignoreCase = true) && a.port == b.port
    }.getOrDefault(false)

    fun mayRedirect(from: String, to: String, carriesCredentials: Boolean): Boolean = runCatching {
        val a = Url(from); val b = Url(to)
        b.protocol.name in setOf("http", "https") && b.user.isNullOrEmpty() && b.password.isNullOrEmpty() &&
            !(a.protocol.name == "https" && b.protocol.name != "https") &&
            (!carriesCredentials || sameOrigin(from, to))
    }.getOrDefault(false)
}

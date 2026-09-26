package com.music.bitchord.data.remote

import kotlin.io.encoding.Base64

/**
 * A WebDAV server treated as a remote folder of audio files.
 *
 * Port of upstream `data/webdav/WebDavConfig.kt`. The id scheme is the part worth
 * knowing about, because it is the whole reason two remote libraries can sit in the
 * same queue as a YouTube track without colliding:
 *
 * ```
 * browse id  "local:webdav"                 the library page
 * track id   "webdav:<absolute file URL>"   a stable id for one file
 * ```
 *
 * The id is the full URL rather than a hash or an index, and that is deliberate: the
 * server may reorder a listing between two launches, and an index would then hand a
 * saved queue the wrong song. A URL does not move.
 *
 * ## The rules here are the ones upstream got wrong on purpose
 *
 * The port changes two things and both are documented at the point of change. The
 * rest — including a bare `host/path` silently becoming HTTPS, which is surprising and
 * is kept — is upstream's.
 */
object WebDavConfig {

    /** The library page's id, in the same namespace as `local:downloads`. */
    const val BROWSE_ID: String = "local:webdav"

    /** The prefix that makes a track id a WebDAV one. */
    const val ID_PREFIX: String = "webdav:"

    /**
     * What counts as a track.
     *
     * `wma`, `aif`, `aiff` and `webm` are listed because files with those
     * extensions really do turn up in a music folder, and refusing to *list* a file
     * somebody can hear on another player would be worse than offering it and having
     * this device decline to decode it. Nothing here promises a decoder.
     */
    val audioExtensions: Set<String> = setOf(
        "mp3", "m4a", "flac", "ogg", "opus", "aac", "wav", "wma", "aif", "aiff", "webm",
    )

    /** What counts as a cover filed beside a track. */
    val imageExtensions: Set<String> = setOf("jpg", "jpeg", "png", "webp")

    /**
     * The address to actually use.
     *
     * Upstream's rule, and a surprising one kept deliberately: a bare `host/path`
     * becomes `https://host/path` without asking. A party server or a share is
     * essentially always HTTPS, and a listener who typed an address without a scheme
     * meant the secure one — but the port adds one thing on top, which is that
     * [isConfigured] insists the result actually parses, so a typo is caught at the
     * point of configuration rather than at the point of the first listing.
     */
    fun normalizeUrl(raw: String): String {
        val trimmed = raw.trim()
        // Slashes on their own are not an address, and treating them as one produces
        // `https://///`, which is a scheme and a host and no server.
        if (trimmed.isEmpty() || trimmed.all { it == '/' }) return ""
        val lower = trimmed.lowercase()
        val hasScheme = lower.startsWith("http://") || lower.startsWith("https://")
        // The trailing slashes are trimmed *after* the scheme, not before it. Trimming
        // first turns `https://` into `https:/`, which is then not a scheme at all —
        // and the address that results is `https://https:/`, whose host is the word
        // "https" and which therefore looks configured.
        val withoutTrailing = trimmed.trimEnd('/')
        return if (hasScheme) withoutTrailing else "https://$withoutTrailing"
    }

    /**
     * Whether an address is one this feature can dial.
     *
     * Stricter than [hostOf] alone, and stricter than upstream, for two reasons that
     * are both about catching a mistake while it is being typed:
     *
     * - A space anywhere refuses. In the host it makes the address unresolvable; in
     *   the path it is sent unencoded and most servers reject it. Both are answered
     *   here with the same sentence the party server's own validation gives, because
     *   it is the same mistake in two features.
     * - A host that is the word `http` or `https` refuses, which is what a scheme that
     *   got eaten by a trailing-slash trim looks like.
     */
    fun isConfigured(url: String): Boolean {
        val normalized = normalizeUrl(url)
        if (normalized.isEmpty()) return false
        if (normalized.any { it.isWhitespace() }) return false
        val lower = normalized.lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false
        val host = hostOf(normalized) ?: return false
        return host != "https" && host != "http"
    }

    /**
     * The `Authorization` header for a set of credentials, or null for none.
     *
     * Null rather than an empty header when both are blank, because some servers
     * answer an empty `Basic` with a 401 that looks exactly like a wrong password, and
     * an open share should be asked with no credential at all.
     */
    fun basicAuthHeader(username: String, password: String): String? {
        if (username.isBlank() && password.isBlank()) return null
        val pair = "$username:$password"
        return "Basic " + Base64.Default.encode(pair.encodeToByteArray())
    }

    /**
     * The host of an address, lower-cased, or null when there is not one.
     *
     * Deliberately host-only and **not** host-and-port. The port has two places
     * where the credential is attached by matching the host — the ranged cover reader
     * and the shared HTTP client — and a share on `example.com:8443` must get the same
     * credential as one on `example.com:443`; matching on the port too would send a
     * secret to a host it does not belong to, and would silently *not* send it to the
     * one it does.
     */
    fun hostOf(url: String): String? {
        val normalized = normalizeUrl(url)
        if (normalized.isEmpty()) return null
        val afterScheme = normalized.substringAfter("://", "")
        // No scheme in the normalized form at all — which can only happen for an empty
        // input, since normalizeUrl adds one.
        if (afterScheme.isEmpty() || afterScheme == normalized) return null
        // The authority ends at the first slash, a query or a fragment.
        val authority = afterScheme.takeWhile { it != '/' && it != '?' && it != '#' }
        // Userinfo first: `sam:pw@host` is a credential, not a host.
        val hostAndPort = authority.substringAfterLast('@')
        val host = if (hostAndPort.startsWith('[')) {
            // A bracketed IPv6 literal: the port is after the closing bracket, and the
            // colons inside the brackets are the address rather than a separator.
            val close = hostAndPort.indexOf(']')
            if (close < 0) return null
            hostAndPort.substring(0, close + 1)
        } else {
            hostAndPort.substringBefore(':')
        }
        if (host.isBlank()) return null
        // A space is the commonest way to arrive at a mistyped address, and an address
        // with one in it is one this feature must refuse rather than try.
        if (host.any { it.isWhitespace() }) return null
        return host.lowercase()
    }

    /**
     * The host **and port** of an address, lower-cased.
     *
     * Deliberately different from [hostOf], and the difference is the point of having
     * both. The credential is attached by host, because a share on
     * `example.com:8443` has to get the credential that belongs to `example.com` and a
     * rule that matched on the port would withhold it from the one host it does belong
     * to. But two servers on one machine at two ports are two *different libraries*,
     * and a grouping key that folded them together would hand one of them the other's
     * covers.
     */
    fun authorityOf(url: String): String? {
        val normalized = normalizeUrl(url)
        if (normalized.isEmpty()) return null
        val afterScheme = normalized.substringAfter("://", "")
        if (afterScheme.isEmpty() || afterScheme == normalized) return null
        val authority = afterScheme.takeWhile { it != '/' && it != '?' && it != '#' }
        val hostAndPort = authority.substringAfterLast('@')
        val host = if (hostAndPort.startsWith('[')) {
            val close = hostAndPort.indexOf(']')
            if (close < 0) return null
            hostAndPort.substring(0, close + 1)
        } else {
            hostAndPort.substringBefore(':')
        }
        if (host.isBlank() || host.any { it.isWhitespace() }) return null
        val port = if (hostAndPort.startsWith('[')) {
            hostAndPort.substringAfter(']', "").trimStart(':')
        } else {
            hostAndPort.substringAfter(':', "")
        }
        return (host + if (port.isBlank()) "" else ":$port").lowercase()
    }

    fun isAudioFile(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase() in audioExtensions
    }

    fun isImageFile(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase() in imageExtensions
    }

    /**
     * A stable track id for a remote file.
     *
     * Prefixed so it never collides with a YouTube id, a local file id, or a module
     * source key — all three of which are unprefixed strings that would otherwise be
     * indistinguishable from one another in a queue, a saved session or a scrobble.
     */
    fun idFor(fileUrl: String): String = ID_PREFIX + fileUrl

    fun isWebDavId(videoId: String): Boolean = videoId.startsWith(ID_PREFIX)

    /**
     * The address a track id plays from, or null when the id is not one.
     *
     * The `http` check is a safety rail rather than decoration: an id is a string
     * that can arrive from a restored session, a saved playlist or a shared link, and
     * handing any of those a `file://` or `smb://` path to the HTTP client would be
     * a request this app has no business making.
     */
    fun fileUrlOf(videoId: String): String? {
        if (!isWebDavId(videoId)) return null
        val url = videoId.removePrefix(ID_PREFIX)
        return url.takeIf { it.startsWith("http://") || it.startsWith("https://") }
    }

    /**
     * The path of an address, with the scheme and authority removed.
     *
     * Every name below is read off this rather than off the whole address. Reading a
     * folder name off a whole URL is how a file at the root of a share ends up
     * labelled with the server's host name — which is a real, shipped-looking album
     * name in a list, and the sort of thing nobody believes until they see it.
     */
    internal fun pathOf(fileUrl: String): String {
        var path = fileUrl.trim()
        val schemeEnd = path.indexOf("://")
        if (schemeEnd >= 0) {
            path = path.substring(schemeEnd + 3)
            val slash = path.indexOf('/')
            path = if (slash >= 0) path.substring(slash) else ""
        }
        return path.substringBefore('?').substringBefore('#').trimEnd('/')
    }

    /** The filename at the end of an address, percent-decoded. */
    fun fileNameOf(fileUrl: String): String {
        val path = pathOf(fileUrl)
        if (path.isEmpty()) return ""
        val segment = path.substringAfterLast('/')
        return percentDecode(segment)
    }

    /** The folder a file sits in, percent-decoded, or null at the root. */
    fun folderNameOf(fileUrl: String): String? {
        val path = pathOf(fileUrl)
        val slash = path.lastIndexOf('/')
        // No slash means the file is at the root, so there is no folder and therefore
        // no album — rather than the empty string a list would render as a blank row.
        if (slash <= 0) return null
        val name = path.substring(0, slash).substringAfterLast('/')
        return percentDecode(name).trim().takeIf { it.isNotEmpty() }
    }

    /**
     * The folder an address is in, as a *key*: the authority and every path segment
     * but the last.
     *
     * Not [folderNameOf], which is a name to print. This is the grouping key for
     * "pictures filed beside this file", and it has to be two things at once that a
     * name is not: it must **include the server**, because two shares routinely have an
     * `AlbumArt.jpg` each and the wrong one is worse than none; and it must **not
     * include the last segment**, because that is the file.
     *
     * The authority is [authorityOf]'s — host *and* port — rather than [hostOf]'s,
     * because two servers on one machine are two libraries and must not borrow each
     * other's covers. Deliberately not lower-cased beyond that, unlike the walk's own
     * visited set: a case-varying server is rare, and a key that folds case together
     * can hand one album another album's cover — a wrong answer — where a key that
     * does not merely loses one.
     */
    fun dirKeyOf(fileUrl: String): String {
        val path = pathOf(fileUrl)
        val slash = path.lastIndexOf('/')
        val directory = if (slash <= 0) "" else path.substring(0, slash)
        return authorityOf(fileUrl).orEmpty() + directory
    }

    /**
     * The name a track is stored under: `Artist - Title.ext`, or the title alone.
     *
     * Filesystem-hostile characters never reach the server — a `/` in a title would
     * otherwise file it into a folder nobody asked for — and the base is cut to 120
     * characters with the extension always appended, because the limit is about what
     * a person can read in a file listing rather than about the path.
     */
    fun uploadFileName(title: String, artist: String, extension: String): String {
        val rawBase = if (artist.isNotBlank() && artist != UNKNOWN_ARTIST) "$artist - $title" else title
        val clean = rawBase
            .map { if (it == '/' || it == '\\' || it.isISOControl()) '_' else it }
            .joinToString("")
            .trim()
            .trim('.')
            .take(120)
            .ifBlank { "track" }
        val ext = extension.lowercase().trimStart('.').takeIf { it.isNotEmpty() } ?: "mp3"
        return "$clean.$ext"
    }

    /**
     * The first name in `base.ext`, `base (1).ext`, `base (2).ext`, … that is not taken.
     *
     * Compared case-insensitively, because a server that ignores case would otherwise
     * hand back a "new" name that collides on disk. The search gives up after a
     * thousand and returns the last candidate, because a name that might collide is
     * better than no upload at all.
     */
    fun resolveNumberedName(base: String, extension: String, taken: Set<String>): String {
        val ext = extension.lowercase().trimStart('.').takeIf { it.isNotEmpty() } ?: "mp3"
        val lowered = taken.map { it.lowercase() }.toSet()
        var candidate = "$base.$ext"
        var n = 0
        while (candidate.lowercase() in lowered && n < 1000) {
            n += 1
            candidate = "$base ($n).$ext"
        }
        return candidate
    }

    /**
     * `root/<segment>`, with the segment percent-encoded.
     *
     * A path is not a query string, so a space is `%20` and never `+` — which is what
     * a form encoder would produce, and what every conventional server will store
     * under a name containing a literal plus.
     */
    fun joinUrl(root: String, segment: String): String {
        val encoded = Percent.encodeSegment(segment)
        return "${root.trimEnd('/')}/$encoded"
    }

    const val UNKNOWN_ARTIST: String = "Unknown Artist"

    private fun percentDecode(value: String): String = Percent.decode(value)
}

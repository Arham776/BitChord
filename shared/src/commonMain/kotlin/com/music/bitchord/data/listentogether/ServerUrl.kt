package com.music.bitchord.data.listentogether

/** Why an address is not a server address. Each case exists because it can be typed. */
sealed interface ServerUrlError {
    /** A space or a tab, anywhere. Almost always a paste that carried formatting. */
    data object Whitespace : ServerUrlError

    /** Not `http` or `https`. */
    data object InvalidScheme : ServerUrlError

    /** No host, or a host that is not a host name. */
    data object InvalidHost : ServerUrlError

    /** A port outside 1..65535, or one that is not a number. */
    data object InvalidPort : ServerUrlError

    /** A `.` or `..` path segment. */
    data object InvalidPath : ServerUrlError

    /** A `?query`. */
    data object HasQuery : ServerUrlError

    /** A `#fragment`. */
    data object HasFragment : ServerUrlError
}

sealed interface ServerUrlValidationResult {
    data class Valid(val normalizedUrl: String) : ServerUrlValidationResult
    data class Invalid(val error: ServerUrlError) : ServerUrlValidationResult
}

val ServerUrlValidationResult.normalizedOrNull: String?
    get() = (this as? ServerUrlValidationResult.Valid)?.normalizedUrl

/**
 * Reading and canonicalising a party server's address.
 *
 * ## Why this is strict, given a base URL is just a string prefix
 *
 * Because it is used as one. Every request is `base + "/api/parties"` and the
 * socket is `base` with the scheme swapped, so anything left in the string is
 * present in every request this device ever makes:
 *
 *  - a **trailing slash** gives `https://host//api/parties`, which some servers
 *    404 and some route differently;
 *  - a **`?query`** is not a base at all — it belongs to one URL, and appending a
 *    path to it produces a request whose query is the path;
 *  - a **`..` segment** walks out of the base entirely, and a base is the one
 *    thing that must not be walked out of.
 *
 * So the function's real job is not to ask "is this a URL" but to return the
 * *canonical* one, such that appending a path to the result is always right. Two
 * addresses that mean the same server have to come out byte-identical, or the
 * same party server looks like two servers to the cache and to the user's own
 * eyes.
 *
 * ## Why each refusal is a refusal
 *
 * Every rule below is a mistake a person actually makes, and each is refused
 * *specifically* so the screen can say what is wrong. "Invalid server address"
 * for all of them is a message that sends somebody to look at a string they
 * cannot see.
 *
 * ## Empty is valid
 *
 * An empty address is [ServerUrlValidationResult.Valid] with an empty string, not
 * an error. That is how "no server is configured" is expressed, and it is the
 * state a fresh install is in — so it has to be representable as an answer rather
 * than as a failure.
 */
object ServerUrl {

    private const val MAX_HOST_LENGTH = 253
    private const val MAX_LABEL_LENGTH = 63
    private val LABEL = Regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$")

    fun parseAndNormalize(raw: String?): ServerUrlValidationResult {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return ServerUrlValidationResult.Valid("")

        if (trimmed.any { it.isWhitespace() }) {
            return ServerUrlValidationResult.Invalid(ServerUrlError.Whitespace)
        }

        // A scheme is filled in rather than demanded, because `jam.example` is what
        // a person types. The default is https and not http: a base URL reaches
        // every request the device makes, and a party carries a join token.
        val withScheme = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val scheme = withScheme.substringBefore("://").lowercase()
        if (scheme != "http" && scheme != "https") {
            return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidScheme)
        }

        val rest = withScheme.substringAfter("://")

        // Checked on the raw remainder, before it is split up, so a `?` in a path
        // position is caught as a query rather than being read as a path segment.
        if ('?' in rest) return ServerUrlValidationResult.Invalid(ServerUrlError.HasQuery)
        if ('#' in rest) return ServerUrlValidationResult.Invalid(ServerUrlError.HasFragment)

        val authority = rest.substringBefore('/')
        val rawPath = rest.substringAfter('/', "")
        if (authority.isEmpty()) return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidHost)

        // Userinfo is dropped rather than refused: it is never meaningful here, and
        // a URL carrying credentials to a party server is not one anybody means.
        val hostPort = authority.substringAfterLast('@')

        val (hostPart, portPart) = splitHostPort(hostPort)
        val port = when {
            portPart == null -> -1
            !portPart.all { it.isDigit() } || portPart.isEmpty() ->
                return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidPort)
            else -> portPart.toIntOrNull()
                ?: return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidPort)
        }
        if (port != -1 && port !in 1..65535) {
            return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidPort)
        }

        val host = canonicalHost(hostPart) ?: return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidHost)

        val segments = rawPath.split('/').filter { it.isNotEmpty() }
        if (segments.any { it == "." || it == ".." }) {
            return ServerUrlValidationResult.Invalid(ServerUrlError.InvalidPath)
        }
        // A base has no trailing slash, so that appending "/api/parties" cannot
        // produce a doubled separator. This is the single most common thing to get
        // wrong about a base URL and the least visible when you do.
        val path = if (segments.isEmpty()) "" else "/" + segments.joinToString("/")

        // The scheme's own default port is dropped (RFC 3986 §6.2.3, scheme-based
        // normalization). Without this, `https://jam.example` and
        // `https://jam.example:443` are byte-different strings for the same
        // server, and this is the function whose whole job is to make sure they
        // are not — the health cache would probe one while the socket dialled the
        // other, and the address box would show two values for one host.
        val isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        val portSuffix = if (port == -1 || isDefaultPort) "" else ":$port"

        return ServerUrlValidationResult.Valid("$scheme://$host$portSuffix$path")
    }

    /**
     * Split an authority into host and port, keeping an IPv6 literal in one piece.
     *
     * The bracket check is the whole reason this is not `split(":")`: without it,
     * `[::1]:8000` loses its port and `[::1]` is read as a host with an empty port.
     */
    private fun splitHostPort(hostPort: String): Pair<String, String?> {
        if (hostPort.startsWith("[")) {
            val close = hostPort.indexOf(']')
            if (close < 0) return hostPort to null
            val host = hostPort.substring(0, close + 1)
            val after = hostPort.substring(close + 1)
            return host to after.takeIf { it.startsWith(":") }?.substring(1)
        }
        val colon = hostPort.lastIndexOf(':')
        if (colon < 0) return hostPort to null
        return hostPort.substring(0, colon) to hostPort.substring(colon + 1)
    }

    /** The canonical form of a host, or null when it is not a host. */
    private fun canonicalHost(rawHost: String): String? {
        if (rawHost.isEmpty()) return null

        // IPv6, bracketed or not, is canonicalised rather than label-checked: a
        // colon in a host can only be an address literal, and treating it as a
        // name is how `[::1]` gets refused as having a malformed label.
        val unbracketed = rawHost.removePrefix("[").removeSuffix("]")
        if (unbracketed.contains(':')) {
            if (unbracketed.isEmpty()) return null
            return "[${unbracketed.lowercase()}]"
        }

        // `localhost` is the one single-label host allowed, because a party server
        // run on a laptop is the single most common case there is. Anything else
        // needs two labels, which refuses `jam` — a real intranet name that would
        // resolve on exactly the network where somebody is typing it.
        if (rawHost.equals("localhost", ignoreCase = true)) return "localhost"

        if (rawHost.length > MAX_HOST_LENGTH) return null
        // A leading or trailing dot is a typo, and a resolver treats it as
        // meaningful: `jam.example.` is a FQDN and `.jam.example` is not.
        if (rawHost.startsWith(".") || rawHost.endsWith(".")) return null

        val labels = rawHost.split('.')
        if (labels.size < 2) return null
        for (label in labels) {
            if (label.isEmpty() || label.length > MAX_LABEL_LENGTH) return null
            if (!label.matches(LABEL)) return null
        }
        return rawHost.lowercase()
    }
}

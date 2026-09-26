package com.music.bitchord.data.listentogether

/**
 * A party code out of a link, wherever the link came from.
 *
 * A code on its own is not enough. A party lives on *a* server, and somebody
 * running their own needs the invite to carry its address — otherwise the link
 * silently joins the wrong party, or fails against a server that has never heard
 * of it. So the server is carried alongside whenever the link has one, and the
 * host's own configured server is used when it does not.
 */
data class ParsedJamInvite(
    val code: String,
    val serverUrl: String? = null,
)

/**
 * Reads party invites, from a web link or the custom scheme.
 *
 * ## What is refused, and why each refusal is a refusal
 *
 * This parses a string that arrived from outside the app — a link somebody
 * tapped, an `onOpenURL` from another application — into a code that will be sent
 * to a server as a credential-free join request. So it is deliberately strict
 * about the two things that could go wrong: the code's length, which is checked
 * against what a code actually looks like rather than merely being non-empty, and
 * the server, which is only accepted if it parses as a host.
 *
 * A permissive parser here does not fail visibly. It produces a code that does not
 * exist, and the symptom is "invite links do not work" on somebody else's device.
 */
object JamInviteLink {

    const val ORIGIN = "https://bitchord.kushagrasingh.in"

    const val HOST = "bitchord.kushagrasingh.in"
    const val CUSTOM_SCHEME = "bitchord"
    const val CUSTOM_HOST = "party"

    /**
     * How long a party code is.
     *
     * Named here rather than taken from the client so the link format and the
     * server agree by construction: a code of a different length is a code for a
     * different protocol, not one this parser should try.
     */
    const val CODE_LENGTH = 6

    /**
     * Read an invite from a URL, or null when this is not one.
     *
     * Two shapes are accepted, because both are real: a custom-scheme link, which
     * is what the app's own share sheet produces, and the web domain, which is
     * what somebody pasting into a chat gets.
     */
    fun parseInvite(value: String?): ParsedJamInvite? {
        val raw = value?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val scheme = raw.substringBefore("://", "").lowercase()
        val host = raw.substringAfter("://", "").substringBefore('/').substringBefore('?').lowercase()
        if (scheme.isEmpty() || host.isEmpty()) return null

        val path = raw.substringAfter("://", "").substringAfter('/', "").substringBefore('?')
        val query = raw.substringAfter('?', "").substringBefore('#')
        val server = sanitizeServerUrl(queryParam(query, "server"))

        // A custom scheme: `bitchord://party/<CODE>` or `bitchord://party?code=<CODE>`.
        if (scheme == CUSTOM_SCHEME && host == CUSTOM_HOST) {
            val fromPath = path.trim('/').takeIf { it.isNotEmpty() }
            val candidate = fromPath ?: queryParam(query, "code") ?: return null
            val code = cleanCode(candidate) ?: return null
            return ParsedJamInvite(code = code, serverUrl = server)
        }

        // The web domain: `https://bitchord.kushagrasingh.in/invite/<CODE>`.
        if (scheme == "https" && host == HOST) {
            val match = INVITE_PATH.matchEntire(path) ?: return null
            return ParsedJamInvite(code = match.groupValues[1].uppercase(), serverUrl = server)
        }

        return null
    }

    /** Whether this looks like an invite at all, for deciding to offer to open it. */
    fun looksLikeInvite(value: String?): Boolean {
        val raw = value?.trim().orEmpty()
        val scheme = raw.substringBefore("://", "").lowercase()
        val host = raw.substringAfter("://", "").substringBefore('/').substringBefore('?').lowercase()
        return (scheme == CUSTOM_SCHEME && host == CUSTOM_HOST) || (scheme == "https" && host == HOST)
    }

    /**
     * A party code, or null when this is not one.
     *
     * Everything that is not a letter or a digit is dropped, then the *length* is
     * checked. Both halves matter and they are not redundant: the filter is what
     * lets a code survive being pasted with a stray character, and the length is
     * what stops a whole sentence being accepted as a code and then failing
     * silently against the server.
     */
    internal fun cleanCode(raw: String): String? {
        val cleaned = raw.filter { it.isLetterOrDigit() }.uppercase()
        return cleaned.takeIf { it.length == CODE_LENGTH }
    }

    /**
     * The server an invite names, or null when it names none or names nonsense.
     *
     * A missing scheme is filled in rather than refused, because `server=jam.example`
     * is what a person types and `server=https://jam.example` is what a tool
     * produces. A missing *host* is refused, because that is not a server address.
     */
    internal fun sanitizeServerUrl(raw: String?): String? {
        val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        // The scheme is tested *before* any trailing slash is removed, and the order
        // matters: `trimEnd('/')` on "https://" leaves "https:", which no longer
        // looks like a URL, so the scheme gets prefixed onto it and the result is
        // "https://https:" — a host that passes every check below and is not a
        // server.
        val withScheme = if (
            trimmed.startsWith("http://", ignoreCase = true) ||
            trimmed.startsWith("https://", ignoreCase = true)
        ) {
            trimmed
        } else {
            "https://$trimmed"
        }
        val host = withScheme.substringAfter("://", "").substringBefore('/').substringBefore('?')
        if (host.isBlank() || host.contains(' ')) return null
        return withScheme.trimEnd('/').ifEmpty { withScheme }
    }

    /** A query parameter, percent-decoded, matching the name case-insensitively. */
    internal fun queryParam(query: String, name: String): String? {
        if (query.isBlank()) return null
        return query.split('&').asSequence()
            .map { it.split('=', limit = 2) }
            .firstOrNull { it.size == 2 && it[0].equals(name, ignoreCase = true) }
            ?.get(1)
            ?.let { percentDecode(it) }
    }

    /**
     * Percent-decoding, or the value unchanged.
     *
     * Hand-rolled and lenient on purpose: an invite that fails to decode its
     * server parameter is better served by the raw text than by nothing, and the
     * value it is guarding is a host name rather than a secret.
     */
    private fun percentDecode(value: String): String {
        if ('%' !in value) return value
        val out = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val ch = value[index]
            if (ch == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    out.append(hex.toChar())
                    index += 3
                    continue
                }
            }
            // `+` is a space only in form encoding, and treating it as one would
            // corrupt a query value that genuinely contains a plus.
            out.append(ch)
            index++
        }
        return out.toString()
    }

    private val INVITE_PATH = Regex("""^/?invite/([A-Za-z0-9]{$CODE_LENGTH})/?$""")
}

package com.music.bitchord.data.remote

/**
 * Percent-encoding for one path segment.
 *
 * Upstream uses `java.net.URLDecoder`, which is a *form* decoder: it decodes `+` as a
 * space and throws on a malformed escape. Neither is wanted here. A `+` in a filename
 * is a plus, and a server that has one escapes it as `%2B` — treating it as a space
 * renames the file in the listener's own library. And a malformed escape comes from
 * filesystems that allow a literal `%` in a name, which is not a reason to lose the
 * character or to fail the listing it appeared in.
 *
 * So: bytes, not characters. A run of escapes is collected as bytes and decoded as
 * UTF-8 at the end, because `é` is `%C3%A9` and appending those two escapes as two
 * characters gives `Ã©` — mojibake in a filename, in an album name, and in a search
 * that then cannot find the file it is searching for.
 */
internal object Percent {

    private const val HEX = "0123456789ABCDEF"

    /** Decoded as far as the escapes are well-formed, and left alone where they are not. */
    fun decode(value: String): String {
        if ('%' !in value) return value
        val bytes = ArrayList<Byte>(value.length)
        var index = 0
        while (index < value.length) {
            val ch = value[index]
            if (ch == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes.add(hex.toByte())
                    index += 3
                    continue
                }
            }
            for (byte in ch.toString().encodeToByteArray()) bytes.add(byte)
            index++
        }
        return bytes.toByteArray().decodeToString()
    }

    /**
     * RFC 3986's `pchar` less `sub-delims`, which is what every server accepts
     * unencoded and what makes the result readable.
     *
     * Everything else — spaces, quotes, `#`, `?` — is escaped, because each of those
     * silently changes the path if it arrives raw.
     */
    fun encodeSegment(segment: String): String {
        val safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"
        val out = StringBuilder(segment.length)
        for (byte in segment.encodeToByteArray()) {
            val char = byte.toInt().toChar()
            if (byte >= 0 && safe.indexOf(char) >= 0) {
                out.append(char)
            } else {
                out.append('%')
                out.append(HEX[(byte.toInt() shr 4) and 0xF])
                out.append(HEX[byte.toInt() and 0xF])
            }
        }
        return out.toString()
    }
}

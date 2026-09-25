package com.music.bitchord.data.lyrics

/**
 * Just enough HTML to read one element's text out of a page.
 *
 * ## Why not a parser
 *
 * A real DOM is the right tool for a document you intend to *navigate*. This is
 * not that: the job is "find this element, drop these subtrees, turn block-level
 * tags into newlines, give me the rest as text", over a region small enough that
 * the answers are unambiguous. A dependency for it would be a parser we ship,
 * keep current, and call in one place.
 *
 * So this is a tag scanner with a depth counter, and the two things it has to get
 * right are spelled out below.
 *
 * ## The two things that are easy to get wrong
 *
 * **Depth, not pattern.** Genius nests `div`s inside the lyric container, and one
 * of the subtrees to remove is a `div`. Cutting at the first `</div>` would keep a
 * fragment and render its tail as lyric text; cutting at the last would keep the
 * "you might also like" block as a line of the song. Every open tag of the
 * element's own name increments and every close decrements, so nesting is
 * counted rather than guessed.
 *
 * **Suppression is a subtree, not a span.** `data-exclude-from-selection` marks
 * a *container* — the header, an ad slot — and the content inside it is markup,
 * not words. Skipping to the next close tag would be right for a leaf and wrong
 * for this, so suppression counts depth too.
 */
internal object HtmlText {

    /**
     * The text of the first `<tag>` whose attributes satisfy [wanted], with
     * newlines where the markup implies a line break.
     *
     * @param skipWhen attributes that mark a subtree to leave out entirely.
     * @return null when no such element is there.
     */
    fun textOfFirstElement(
        html: String,
        tag: String,
        wanted: (String) -> Boolean,
        skipWhen: (String) -> Boolean = { false },
        blockTags: Set<String> = DEFAULT_BLOCK_TAGS,
    ): String? {
        val region = regionOfFirstElement(html, tag, wanted) ?: return null
        return toText(region, skipWhen, blockTags)
    }

    /** The markup of the first matching element, tags included. */
    private fun regionOfFirstElement(
        html: String,
        tag: String,
        wanted: (String) -> Boolean,
    ): String? {
        val open = Regex(
            """<$tag\b([^>]*?)/?>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )
        // Every candidate, not just the first: a page has many `<div>`s and the one
        // we want is the one carrying the attribute, which is rarely the first.
        for (candidate in open.findAll(html)) {
            val attributes = candidate.groupValues[1]
            if (!wanted(attributes)) continue
            // A self-closing element has no content at all.
            if (candidate.value.trimEnd().endsWith("/>")) return ""
            val index = candidate.range.last + 1
            // Only tags of *this* name count toward the depth. Counting a foreign
            // `<br/>` as an opening tag would run the depth away and swallow the
            // rest of the document — which is exactly what it did the first time.
            val scanner = Regex(
                """<(/?)$tag\b[^>]*>""",
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
            )
            var depth = 1
            for (match in scanner.findAll(html, index)) {
                if (match.value.trimStart().startsWith("</")) {
                    depth--
                    if (depth == 0) return html.substring(index, match.range.first)
                } else {
                    depth++
                }
            }
            // Unclosed at the end of the document: take what is there rather than
            // nothing, since the content is what the caller came for.
            return html.substring(index)
        }
        return null
    }

    /** The text of [region], with markup resolved. */
    fun toText(
        region: String,
        skipWhen: (String) -> Boolean = { false },
        blockTags: Set<String> = DEFAULT_BLOCK_TAGS,
    ): String {
        val out = StringBuilder()
        // Tag name currently being suppressed, and how deep we are inside it.
        var skipping: String? = null
        var skipDepth = 0

        val tagPattern = Regex("""<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>""", RegexOption.DOT_MATCHES_ALL)
        var cursor = 0
        for (match in tagPattern.findAll(region)) {
            if (skipping == null) {
                out.append(decodeEntities(region.substring(cursor, match.range.first)))
            }
            cursor = match.range.last + 1

            val closing = match.groupValues[1] == "/"
            val name = match.groupValues[2].lowercase()
            val attributes = match.groupValues[3]

            // A script or style body is code, not words, and reading it would put
            // JavaScript on screen in time with the music.
            if (name in CODE_TAGS) {
                if (skipping == null && !closing) {
                    skipping = name
                    skipDepth = 1
                } else if (skipping != null) {
                    if (name == skipping) skipDepth += if (closing) -1 else 1
                    if (skipDepth <= 0) skipping = null
                }
                continue
            }

            if (skipping != null) {
                if (name == skipping) skipDepth += if (closing) -1 else 1
                if (skipDepth <= 0) skipping = null
                continue
            }
            if (!closing && skipWhen(attributes)) {
                skipping = name
                skipDepth = 1
                continue
            }
            if (skipping != null) continue
            when {
                name == "br" -> out.append('\n')
                closing && name in blockTags -> out.append('\n')
                !closing && name in blockTags -> out.append('\n')
            }
        }
        if (skipping == null) out.append(decodeEntities(region.substring(cursor)))
        return out.toString()
    }

    /**
     * The handful of entities a lyrics page actually contains.
     *
     * Deliberately not the full set: an unknown entity is passed through as its
     * literal text rather than dropped, because a dropped character inside a word
     * is a typo the listener reads and an ampersand they can see is not.
     */
    fun decodeEntities(value: String): String {
        if ('&' !in value) return value
        var out = value
        for ((entity, replacement) in ENTITIES) {
            if (entity in out) out = out.replace(entity, replacement)
        }
        return decodeNumericEntities(out)
    }

    private fun decodeNumericEntities(value: String): String {
        if ("&#" !in value) return value
        val out = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val ch = value[index]
            if (ch != '&' || index + 2 >= value.length || value[index + 1] != '#') {
                out.append(ch)
                index++
                continue
            }
            val hex = index + 3 < value.length &&
                (value[index + 2] == 'x' || value[index + 2] == 'X')
            val digitsFrom = index + (if (hex) 3 else 2)
            var end = digitsFrom
            while (end < value.length && value[end].isLetterOrDigit()) end++
            if (end == digitsFrom || (end < value.length && value[end] != ';')) {
                out.append(ch)
                index++
                continue
            }
            val code = value.substring(digitsFrom, end).toIntOrNull(16.takeIf { hex } ?: 10)
            if (code == null || code !in 1..0x10FFFF) {
                out.append(ch)
                index++
                continue
            }
            out.appendCodePointCompat(code)
            index = end + 1
        }
        return out.toString()
    }

    private fun StringBuilder.appendCodePointCompat(code: Int) {
        if (code < 0x10000) {
            append(code.toChar())
        } else {
            val adjusted = code - 0x10000
            append((0xD800 + (adjusted shr 10)).toChar())
            append((0xDC00 + (adjusted and 0x3FF)).toChar())
        }
    }

    private val ENTITIES = listOf(
        "&nbsp;" to " ", "&amp;" to "&", "&lt;" to "<", "&gt;" to ">",
        "&quot;" to "\"", "&#39;" to "'", "&apos;" to "'", "&mdash;" to "—",
        "&ndash;" to "–", "&hellip;" to "…", "&rsquo;" to "’", "&lsquo;" to "‘",
        "&ldquo;" to "“", "&rdquo;" to "”",
    )

    /** Elements whose content is code rather than text. */
    private val CODE_TAGS = setOf("script", "style", "noscript", "template")

    /** Tags that imply a line break when they open or close. */
    val DEFAULT_BLOCK_TAGS = setOf(
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "blockquote", "pre", "figure",
    )
}

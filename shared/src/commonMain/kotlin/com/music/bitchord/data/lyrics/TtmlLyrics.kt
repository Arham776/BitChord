package com.music.bitchord.data.lyrics

/**
 * Apple Music TTML — `<p>` lines with timed `<span>` syllables.
 * Regex-based so commonMain does not need an XML parser.
 */
object TtmlLyrics {

    private val P = Regex(
        """<p\b([^>]*)>(.*?)</p>""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    private val SPAN = Regex(
        """<span\b([^>]*)>(.*?)</span>""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    private val BEGIN = Regex("""begin="([^"]+)"""")
    private val END = Regex("""end="([^"]+)"""")
    private val ROLE = Regex("""ttm:role="([^"]+)"""")

    fun parse(ttml: String): List<LyricLineDto> {
        return P.findAll(ttml).mapNotNull { p ->
            val attrs = p.groupValues[1]
            val role = ROLE.find(attrs)?.groupValues?.get(1).orEmpty()
            if (role == "x-translation" || role == "x-roman") return@mapNotNull null
            val inner = p.groupValues[2]
            val words = SPAN.findAll(inner).mapNotNull { span ->
                val sattrs = span.groupValues[1]
                val srole = ROLE.find(sattrs)?.groupValues?.get(1).orEmpty()
                if (srole == "x-translation" || srole == "x-roman") return@mapNotNull null
                val begin = time(BEGIN.find(sattrs)?.groupValues?.get(1)) ?: return@mapNotNull null
                val end = time(END.find(sattrs)?.groupValues?.get(1)) ?: begin + 200
                val text = span.groupValues[2].replace(Regex("<[^>]+>"), "").trim()
                if (text.isEmpty()) null else LyricWordDto(begin, end, decode(text))
            }.toList()
            val pBegin = time(BEGIN.find(attrs)?.groupValues?.get(1))
            if (words.isNotEmpty()) {
                LyricLineDto(
                    timeMs = minOf(pBegin ?: words.first().startMs, words.first().startMs),
                    text = words.joinToString(" ") { it.text },
                    words = words,
                )
            } else {
                val text = decode(inner.replace(Regex("<[^>]+>"), "").trim())
                if (text.isEmpty() || pBegin == null) null
                else LyricLineDto(pBegin, text)
            }
        }.sortedBy { it.timeMs }.toList()
    }

    internal fun time(value: String?): Long? {
        val raw = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (raw.endsWith("ms")) return raw.dropLast(2).toDoubleOrNull()?.toLong()
        val stripped = raw.removeSuffix("s")
        val parts = stripped.split(':')
        val seconds = when (parts.size) {
            1 -> parts[0].toDoubleOrNull()
            2 -> parts[0].toDoubleOrNull()?.let { m -> parts[1].toDoubleOrNull()?.let { m * 60 + it } }
            3 -> parts[0].toDoubleOrNull()?.let { h ->
                parts[1].toDoubleOrNull()?.let { m ->
                    parts[2].toDoubleOrNull()?.let { h * 3600 + m * 60 + it }
                }
            }
            else -> null
        } ?: return null
        return (seconds * 1000).toLong()
    }

    private fun decode(text: String): String = EnhancedLrc.decodeEntities(text)
}

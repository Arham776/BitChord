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
            val lead = mutableListOf<LyricWordDto>()
            val backing = mutableListOf<LyricWordDto>()
            SPAN.findAll(inner).forEach { span ->
                val sattrs = span.groupValues[1]
                val srole = ROLE.find(sattrs)?.groupValues?.get(1).orEmpty()
                if (srole == "x-translation" || srole == "x-roman") return@forEach
                val begin = time(BEGIN.find(sattrs)?.groupValues?.get(1)) ?: return@forEach
                val end = time(END.find(sattrs)?.groupValues?.get(1)) ?: begin + 200
                val text = span.groupValues[2].replace(Regex("<[^>]+>"), "").trim()
                if (text.isEmpty()) return@forEach
                val word = LyricWordDto(begin, end, decode(text))
                if (srole == "x-bg") backing += word else lead += word
            }
            val pBegin = time(BEGIN.find(attrs)?.groupValues?.get(1))
            val pEnd = time(END.find(attrs)?.groupValues?.get(1))
            val background = backing.takeIf { it.isNotEmpty() }?.let {
                LyricLineDto(
                    timeMs = it.first().startMs,
                    text = it.joinToString(" ") { w -> w.text },
                    words = it,
                )
            }
            if (lead.isNotEmpty()) {
                LyricLineDto(
                    timeMs = minOf(pBegin ?: lead.first().startMs, lead.first().startMs),
                    text = lead.joinToString(" ") { it.text },
                    words = lead,
                    background = background,
                )
            } else {
                val text = decode(inner.replace(Regex("<[^>]+>"), "").trim())
                if (text.isEmpty() || pBegin == null) null
                else LyricLineDto(pBegin, text, sungUntilMs = pEnd?.takeIf { it > pBegin }, background = background)
            }
        }.sortedBy { it.timeMs }.toList().withInstrumentalGaps()
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

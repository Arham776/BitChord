package com.music.bitchord.data.lyrics

/**
 * Enhanced ("A2") LRC — a normal LRC line with a stamp in front of each word:
 *
 * ```
 * [00:27.39]<00:27.39>I <00:27.54>been <00:27.74>tryna
 * ```
 */
object EnhancedLrc {

    private val LINE = Regex("""^\[(\d{1,3}):(\d{2})[.:](\d{2,3})](.*)$""")
    private val WORD = Regex("""<(\d{1,3}):(\d{2})[.:](\d{2,3})>([^<]*)""")
    private const val TAIL_MS = 800L

    fun parse(lrc: String): List<LyricLineDto> {
        val rows = lrc.lineSequence().mapNotNull { raw ->
            val match = LINE.matchEntire(raw.trim()) ?: return@mapNotNull null
            val timeMs = stamp(match.groupValues[1], match.groupValues[2], match.groupValues[3])
            val body = match.groupValues[4]
            val words = WORD.findAll(body).toList()
            Triple(timeMs, words, body.replace(WORD, "").trim())
        }.sortedBy { it.first }.toList()
        if (rows.none { it.second.isNotEmpty() }) return emptyList()

        return rows.mapIndexedNotNull { index, (timeMs, wordMatches, plain) ->
            if (wordMatches.isEmpty()) {
                if (plain.isEmpty()) null else LyricLineDto(timeMs, decodeEntities(plain))
            } else {
                val lineEnd = rows.getOrNull(index + 1)?.first ?: (stamp(wordMatches.last()) + TAIL_MS)
                val words = wordMatches.mapIndexedNotNull { i, match ->
                    val text = decodeEntities(match.groupValues[4]).trim()
                    if (text.isEmpty()) return@mapIndexedNotNull null
                    val start = stamp(match)
                    val end = wordMatches.getOrNull(i + 1)?.let { stamp(it) } ?: lineEnd
                    LyricWordDto(start, end.coerceAtLeast(start), text)
                }
                if (words.isEmpty()) null
                else LyricLineDto(
                    timeMs = minOf(timeMs, words.first().startMs),
                    text = words.joinToString(" ") { it.text },
                    words = words,
                )
            }
        }
    }

    private fun stamp(match: MatchResult): Long =
        stamp(match.groupValues[1], match.groupValues[2], match.groupValues[3])

    private fun stamp(minutes: String, seconds: String, fraction: String): Long {
        val fractionMs = if (fraction.length == 3) fraction.toLong() else fraction.toLong() * 10
        return minutes.toLong() * 60_000 + seconds.toLong() * 1_000 + fractionMs
    }

    internal fun decodeEntities(text: String): String {
        if ('&' !in text) return text
        return text
            .replace("&#x27;", "'")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&quot;", "\"")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
    }
}

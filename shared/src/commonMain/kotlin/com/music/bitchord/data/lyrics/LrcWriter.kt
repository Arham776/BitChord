package com.music.bitchord.data.lyrics

/** Turns parsed lines back into the text of an LRC file. Word timings dropped. */
internal fun List<LyricLineDto>.toLrc(): String {
    if (isEmpty()) return ""
    return sortedBy { it.timeMs }.joinToString("\n") { line -> stamp(line.timeMs) + line.flattened() }
}

private fun LyricLineDto.flattened(): String =
    background?.let { (text + " " + it.text).trim() } ?: text

internal const val WORD_LYRICS_FIELD = "BITCHORD_LYRICS"

internal fun List<LyricLineDto>.toEnhancedLrc(): String {
    if (isEmpty()) return ""
    if (none { it.isWordSynced || it.background?.isWordSynced == true }) return ""
    return sortedBy { it.timeMs }.joinToString("\n") { line -> stamp(line.timeMs) + line.enhancedBody() }
}

private fun LyricLineDto.enhancedBody(): String {
    val runs = timedRuns()
    if (runs.isEmpty()) return flattened()
    val out = StringBuilder()
    var previous = timeMs
    runs.forEachIndexed { index, word ->
        val start = maxOf(word.startMs, previous)
        out.append(wordStamp(start)).append(word.text)
        if (index != runs.lastIndex) out.append(' ')
        previous = start
    }
    out.append(wordStamp(maxOf(runs.maxOf { it.endMs }, previous)))
    return out.toString()
}

private fun LyricLineDto.timedRuns(): List<LyricWordDto> {
    if (words.isEmpty()) return emptyList()
    val answer = background?.let { bg ->
        bg.words.ifEmpty {
            if (bg.text.isBlank()) emptyList() else listOf(LyricWordDto(bg.timeMs, bg.endMs, bg.text))
        }
    }.orEmpty()
    return words + answer
}

private fun stamp(timeMs: Long): String = "[" + clock(timeMs) + "]"

private fun wordStamp(timeMs: Long): String = "<" + clock(timeMs) + ">"

private fun clock(timeMs: Long): String {
    val total = timeMs.coerceAtLeast(0L)
    val minutes = (total / 60_000).toString().padStart(2, '0')
    val seconds = (total % 60_000 / 1_000).toString().padStart(2, '0')
    val centiseconds = (total % 1_000 / 10).toString().padStart(2, '0')
    return "$minutes:$seconds.$centiseconds"
}

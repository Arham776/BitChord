package com.music.bitchord.data.lyrics

/**
 * Pulls the answering vocal out of a line and hangs it underneath, as
 * [LyricLineDto.background].
 */
internal fun List<LyricLineDto>.withBackgroundVocals(): List<LyricLineDto> =
    map { it.splitTrailingBracket() }

private fun LyricLineDto.splitTrailingBracket(): LyricLineDto {
    if (background != null || isGap) return this

    val open = bracketStart(text) ?: return this
    val lead = text.substring(0, open).trimEnd()
    val backing = text.substring(open).trim()
    if (lead.isEmpty() || !backing.any { it.isLetterOrDigit() }) return this

    if (words.isEmpty()) {
        return copy(
            text = lead,
            background = LyricLineDto(timeMs, backing, sungUntilMs = sungUntilMs),
        )
    }

    val split = words.indexOfFirstStartingAt(open) ?: return this
    if (split <= 0) return this

    val backingWords = words.drop(split)
    return copy(
        text = lead,
        words = words.take(split),
        background = LyricLineDto(
            timeMs = backingWords.first().startMs,
            text = backing,
            words = backingWords,
        ),
    )
}

private fun List<LyricWordDto>.indexOfFirstStartingAt(offset: Int): Int? {
    var at = 0
    forEachIndexed { index, word ->
        if (at == offset) return index
        if (at > offset) return null
        at += word.text.length + 1
    }
    return null
}

private fun bracketStart(text: String): Int? {
    if (!text.endsWith(')')) return null
    var depth = 0
    for (index in text.indices.reversed()) {
        when (text[index]) {
            ')' -> depth++
            '(' -> {
                depth--
                if (depth == 0) return index.takeIf { it > 0 }
            }
        }
    }
    return null
}

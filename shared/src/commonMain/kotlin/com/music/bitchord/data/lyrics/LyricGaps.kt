package com.music.bitchord.data.lyrics

/** Shorter instrumental breaks aren't worth interrupting the line for. */
internal const val MIN_GAP_MS = 4_000L

/**
 * Marks the instrumental stretches with blank lines, the way an LRC file
 * marks them with a bare timestamp.
 */
internal fun List<LyricLineDto>.withInstrumentalGaps(): List<LyricLineDto> {
    if (isEmpty()) return this
    val out = ArrayList<LyricLineDto>(size + 4)
    if (first().timeMs >= MIN_GAP_MS) out += LyricLineDto(0L, "")
    forEachIndexed { index, line ->
        out += line
        val next = getOrNull(index + 1) ?: return@forEachIndexed
        if (!line.hasKnownEnd) return@forEachIndexed
        val silence = next.timeMs - line.endMs
        if (silence >= MIN_GAP_MS && line.endMs > line.timeMs) out += LyricLineDto(line.endMs, "")
    }
    return out
}

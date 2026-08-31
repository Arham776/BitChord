package com.music.bitchord.data.lyrics

/** One word/syllable inside a line. */
data class LyricWordDto(
    val startMs: Long,
    val endMs: Long,
    val text: String,
)

/** One synced line. Blank [text] is an instrumental gap. */
data class LyricLineDto(
    val timeMs: Long,
    val text: String,
    val words: List<LyricWordDto> = emptyList(),
    val wordSynced: Boolean = words.isNotEmpty(),
) {
    val isGap: Boolean get() = text.isEmpty()
}

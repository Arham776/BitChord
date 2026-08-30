package com.music.bitchord.data.lyrics

/** One synced line. Blank [text] is an instrumental gap. */
data class LyricLineDto(
    val timeMs: Long,
    val text: String,
) {
    val isGap: Boolean get() = text.isEmpty()
}

package com.music.bitchord.data.lyrics

/** One word/syllable inside a line. */
data class LyricWordDto(
    val startMs: Long,
    val endMs: Long,
    val text: String,
)

/**
 * One synced line. Blank [text] is an instrumental gap.
 *
 * [background] is the answering vocal drawn under the lead — see
 * [withBackgroundVocals]. [sungUntilMs] is a line-synced provider's own end.
 */
data class LyricLineDto(
    val timeMs: Long,
    val text: String,
    val words: List<LyricWordDto> = emptyList(),
    val sungUntilMs: Long? = null,
    val background: LyricLineDto? = null,
) {
    val isGap: Boolean get() = text.isEmpty()

    val wordSynced: Boolean get() = words.isNotEmpty()

    val isWordSynced: Boolean get() = wordSynced

    val hasKnownEnd: Boolean get() = words.isNotEmpty() || sungUntilMs != null

    val endMs: Long
        get() {
            val lead = words.lastOrNull()?.endMs ?: sungUntilMs ?: timeMs
            return maxOf(lead, background?.endMs ?: lead)
        }
}

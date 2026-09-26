package com.music.bitchord.data.lyrics

import kotlinx.serialization.Serializable

/** One word/syllable inside a line. */
@Serializable
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
 *
 * Serializable because a translated lyric crosses to the host as a document: the
 * host needs the whole line back, timings and background included, or the
 * translation would not stay in step with the music.
 */
@Serializable
data class LyricLineDto(
    val timeMs: Long,
    val text: String,
    val words: List<LyricWordDto> = emptyList(),
    val sungUntilMs: Long? = null,
    val background: LyricLineDto? = null,
    /**
     * Which side of the panel this line is sung from.
     *
     * A duet is written in TTML as a `ttm:agent` per line, and the two voices are
     * laid out on opposite sides so a call-and-response reads as two people rather
     * than one long verse. [LyricAlignment.Start] is the default and the only side
     * a single-voice song ever uses — which is every provider but Apple's.
     */
    val alignment: LyricAlignment = LyricAlignment.Start,
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

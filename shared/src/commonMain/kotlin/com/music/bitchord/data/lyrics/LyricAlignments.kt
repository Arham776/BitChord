package com.music.bitchord.data.lyrics

/**
 * Which side of the panel a line is sung from.
 *
 * A duet is written in TTML as a `ttm:agent` per line, and Apple lays the two
 * voices out on opposite sides so a call-and-response reads as two people rather
 * than one long verse. [Start] is the default and the only side a single-voice
 * song ever uses.
 */
enum class LyricAlignment { Start, End }

/** `ttm:agent` types, as both TTML and LyricsPlus name them. */
private const val PERSON = "person"
private const val GROUP = "group"
private const val OTHER = "other"

/** Apple's two reserved voices: everyone at once, and the other singer. */
private const val GROUP_AGENT = "v1000"
private const val OTHER_AGENT = "v2000"

/**
 * Past this share of lines on the right, the whole song is flipped — see
 * [lineAlignments]. Not 100%: a chorus or two sung by the group lands wherever
 * it lands and would otherwise be enough to call it a genuine duet.
 */
private const val MOSTLY_RIGHT = 0.85f

/**
 * Which side each line is sung from, given the voice that sang it.
 *
 * ## Not one side per voice
 *
 * The sides alternate every time the voice *changes*, which is what keeps a
 * three-way song reading as a conversation rather than putting two of the three
 * on top of each other. A line sung by everyone at once ([GROUP]) belongs to
 * neither side, and stays where it is without disturbing whose turn it is.
 *
 * ## Why the whole song is flipped at the end
 *
 * The walk starts on the left, so a song that *opens* on the voice it starts
 * away from comes out laid out entirely down the right-hand side — correct by the
 * rule and plainly not what was meant. Almost every line being on the right is
 * the signature of that, and the fix is to flip the whole thing rather than to
 * change the walk's starting side, which would move the same mistake to every
 * song that opens on the other voice.
 *
 * ## Why [types] is a map and not a guess
 *
 * An agent's declared type decides whether it is a person, the group or
 * something else, and only the id is on the line itself. Where the head does not
 * declare one — which is common enough to be worth handling — the two reserved
 * ids still mean specific things, and anything else is a person.
 */
internal fun lineAlignments(
    singers: List<String?>,
    types: Map<String, String>,
): List<LyricAlignment> {
    var left = true
    var lastVoice: String? = null
    var rightward = 0
    var placed = 0

    val sides = singers.map { singer ->
        if (singer.isNullOrEmpty()) return@map LyricAlignment.Start
        val type = types[singer] ?: when (singer) {
            GROUP_AGENT -> GROUP
            OTHER_AGENT -> OTHER
            else -> PERSON
        }
        placed += 1
        if (type == GROUP) return@map LyricAlignment.Start

        when {
            lastVoice == null -> left = type != OTHER
            singer != lastVoice -> left = !left
        }
        lastVoice = singer

        if (!left) rightward += 1
        if (left) LyricAlignment.Start else LyricAlignment.End
    }

    // Nothing was placed, so there is nothing to flip, and a share of a share
    // would be a number from nothing.
    if (placed == 0 || rightward.toFloat() / placed < MOSTLY_RIGHT) return sides
    return sides.map {
        if (it == LyricAlignment.Start) LyricAlignment.End else LyricAlignment.Start
    }
}

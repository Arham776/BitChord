package com.music.bitchord.data.lyrics

/**
 * A YouTube title, as a lyrics database would have indexed it.
 *
 * Every source here but [SimpMusicLyrics] is asked for a name, and the name this
 * app has is YouTube's, which is not the name anyone catalogued. "Dracula (feat.
 * JENNIE)" is filed by Apple, LRCLIB and everyone else as "Dracula", and asked
 * for verbatim it misses all of them — which is exactly how a track ends up
 * answered by whichever source happened to clean the title on its own. The
 * repository now cleans once for every provider, including a leading artist
 * credit on upload-style titles.
 *
 * ## What is taken off, and what is deliberately left on
 *
 * Only credits and packaging: who else is on the record, and how the upload was
 * labelled. Those are not part of the recording's name anywhere.
 *
 * Anything that names a *different recording* stays — "(Remix)", "(Acoustic)",
 * "(Live)", "(Remastered 2011)", "(Sped Up)". Those look like the same kind of
 * bracket and are the opposite: stripping them turns a search for one recording
 * into a search for another, and the lyrics that come back are confidently wrong
 * rather than merely missing. A miss is recoverable; the wrong words scrolling in
 * time with the right song is not.
 */
internal fun String.forLyricsSearch(artist: String? = null): String {
    var name = this
    CREDITS.forEach { pattern -> name = pattern.replace(name, " ") }
    name = name.replace(WHITESPACE, " ").trim().trimEnd(',', '-', '\u2013', '\u2014').trim()
        // A title that was *only* packaging is no title at all; better to ask
        // with what we were given than with nothing.
        .ifBlank { trim() }

    // YouTube audio uploads often put the artist in the title itself, sometimes
    // without a dash: "AIKA & NAHREEL FORTY (AUDIO) FT AZAWI". Providers index
    // that recording under just "Forty". Remove a leading artist credit when
    // the artist metadata confirms it; otherwise this upload wrapper makes every
    // exact-title lookup miss.
    val cleanedArtist = artist?.artistForLyricsSearch()
    val credits = cleanedArtist?.split(ARTIST_PREFIX_SEPARATOR)
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        .orEmpty()
    val prefixCandidates = buildList {
        cleanedArtist?.takeIf { it.isNotBlank() }?.let(::add)
        for (count in 1..credits.size) {
            val prefix = credits.take(count)
            add(prefix.joinToString(" & "))
            add(prefix.joinToString(" "))
        }
    }.distinct().sortedByDescending { it.length }

    for (prefix in prefixCandidates) {
        if (name.length <= prefix.length || !name.regionMatches(0, prefix, 0, prefix.length, ignoreCase = true)) {
            continue
        }
        val boundary = name[prefix.length]
        val separatedByPunctuation = boundary in TITLE_PREFIX_SEPARATORS
        // A multiword artist followed by whitespace is the common no-dash
        // upload style. Do not strip a one-word artist from a real title such as
        // "Aika Song" merely because the same word names the performer.
        val separatedByWords = boundary.isWhitespace() && prefix.any { it.isWhitespace() }
        if (!separatedByPunctuation && !separatedByWords) continue
        val remainder = name.substring(prefix.length).trimStart()
            .trimStart('-', '\u2013', '\u2014', ':', '|', '\u00b7')
            .trim()
        if (remainder.isNotEmpty()) return remainder
    }
    return name
}

/**
 * Trims " - Topic" off an auto-generated channel name.
 *
 * YouTube's own artist channels for licensed music are named this way, and it
 * reaches the player as the artist on anything played from one.
 */
internal fun String.artistForLyricsSearch(): String =
    removeSuffix(" - Topic").trim().ifBlank { trim() }

/** Whether this is worth a second pass at all. */
internal fun String.isUsableLyricsQuery(): Boolean = isNotBlank() && length >= MIN_QUERY

/**
 * Below this, a query is punctuation or a single letter and no provider is going
 * to have it.
 *
 * One rather than zero, because a one-character title is a real thing in a few
 * catalogues and a provider that has it should be allowed to say so.
 */
private const val MIN_QUERY = 1

private val WHITESPACE = Regex("""\s+""")
private val ARTIST_PREFIX_SEPARATOR = Regex(
    """(?i)\s*(?:,|&|;|feat(?:uring)?\.?|ft\.?|with|x|·)\s*""",
)
private val TITLE_PREFIX_SEPARATORS = setOf('-', '\u2013', '\u2014', ':', '|', '\u00b7')

/**
 * Brackets, in both widths.
 *
 * The ASCII pair alone is a Latin-only assumption. A Japanese or Chinese upload
 * packages the same credits and the same upload labels in （）, 【】, 「」, 『』,
 * 〈〉, 《》 or 〔〕, and none of those patterns matched: the brackets rode into the
 * provider verbatim, which has never seen them, so the query missed every
 * name-matched source — in exactly the catalogue that is hardest to hit.
 */
private const val OPEN_BRACKET = """[(\[（【「『〈《〔]"""
private const val CLOSE_BRACKET = """[)\]）】」』〉》〕]"""

/**
 * The upload labels themselves, in the scripts whose uploads carry them.
 *
 * Every one describes the *upload* rather than the recording — 歌詞/歌词
 * "lyrics", フル "full", 字幕 "subtitles", 高音質 "high quality" — so the note
 * above still holds: nothing here names a different take, and stripping it
 * cannot turn a search for one recording into a search for another.
 */
private const val UPLOAD_LABELS =
    """(歌詞|歌词|フル|字幕|中日字幕|中文字幕|完整版|高音質|高音质|動画|PV|MV)"""

private val CREDITS = listOf(
    // Bracketed credits: (feat. X), [ft. X], (with X).
    Regex(
        """\s*$OPEN_BRACKET\s*(feat|ft|featuring|with)\b[^)\]）】」』〉》〕]*$CLOSE_BRACKET""",
        RegexOption.IGNORE_CASE,
    ),
    // The same, unbracketed and running to the end of the title.
    Regex("""\s+(feat|ft|featuring)\.?\s+.*$""", RegexOption.IGNORE_CASE),
    // How the upload was labelled, not what was recorded.
    Regex(
        """\s*$OPEN_BRACKET\s*(official\s*)?(music\s*)?""" +
            """(video|audio|visuali[sz]er|lyrics?\s*video|lyrics?|m/?v|hd|hq|4k|full\s*song)""" +
            """\s*$CLOSE_BRACKET""",
        RegexOption.IGNORE_CASE,
    ),
    Regex("""\s*$OPEN_BRACKET\s*official\s*$CLOSE_BRACKET""", RegexOption.IGNORE_CASE),
    // The same labels again in their own scripts, bracketed...
    Regex("""\s*$OPEN_BRACKET\s*$UPLOAD_LABELS\s*$CLOSE_BRACKET""", RegexOption.IGNORE_CASE),
    // ...and simply appended, which is how they are most often written:
    // "夜に駆ける 歌詞". Anchored to the end so a title that happens to contain
    // one of these words is left alone.
    Regex("""\s+$UPLOAD_LABELS\s*${'$'}""", RegexOption.IGNORE_CASE),
)

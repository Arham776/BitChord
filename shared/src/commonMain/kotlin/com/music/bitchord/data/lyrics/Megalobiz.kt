package com.music.bitchord.data.lyrics

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Line-synced community LRC scraped from Megalobiz.
 *
 * A scraper rather than an API, which is worth saying plainly: it breaks when
 * the page changes, and there is nothing to tell it apart from a miss when it
 * does. It is last in the default order for that reason, and it is here because
 * it does hold a long tail of older catalogue that none of the licensed
 * sources carry.
 *
 * ## It is currently broken, and the two regexes are not why
 *
 * Checked on 26 September 2026: `/searchall` answers 404 and `/search/` answers 503.
 * The page this reads is not serving, so there is nothing to match against and the
 * walk returns a miss. Written down because the alternative — seeing "no lyrics" and
 * assuming the database has never heard of the song — is exactly the misreading the
 * note above warns about, and because the next person to look should not have to
 * rediscover that both patterns still work.
 *
 * Fixing it means finding where the search moved, and a guess at a new path is worse
 * than a source that admits it is down: a scraper pointed at the wrong page returns
 * confidently and wrongly.
 */
object Megalobiz {

    private const val BASE = "https://www.megalobiz.com"

    suspend fun lyrics(title: String, artist: String): List<LyricLineDto>? =
        withContext(Dispatchers.Default) {
            val results = lyricsGet("$BASE/searchall", query = mapOf("qry" to "$artist $title".trim()))
                ?: return@withContext null
            val path = LRC_LINK.find(results)?.groupValues?.get(1) ?: return@withContext null
            val page = lyricsGet(BASE + path.replace("&amp;", "&")) ?: return@withContext null
            val raw = LRC_BODY.find(page)?.groupValues?.get(1) ?: return@withContext null
            val lrc = raw.replace(BREAKS, "\n")
                .replace(TAG, "")
                .let(EnhancedLrc::decodeEntities)
            LrcLib.parseLrc(lrc).takeIf { lines -> lines.any { it.text.isNotBlank() } }
        }

    /** The download link out of the results page. */
    private val LRC_LINK =
        Regex("""href=["'](/lrc/maker/download/[^"']+)["']""", RegexOption.IGNORE_CASE)

    /** The lyric body out of the download page, which is a `<span>` and nothing else. */
    private val LRC_BODY = Regex(
        """id=["']lrc_[^"']*_details["'][^>]*>(.*?)</span>""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )

    private val BREAKS = Regex("""(?i)<br\s*/?>""")
    private val TAG = Regex("""<[^>]+>""")
}

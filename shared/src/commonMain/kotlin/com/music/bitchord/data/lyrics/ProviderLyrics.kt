package com.music.bitchord.data.lyrics

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Turns the wire formats used by the smaller providers into BitChord lyrics.
 *
 * The sniff rather than a decode, because these are not one format. The same
 * endpoint will hand back TTML on one track, Karaoke LRC on the next and plain
 * text on a third, sometimes inside a JSON envelope and sometimes not — and the
 * only thing that says which is the body itself. Decoding into a declared shape
 * meant the body silently produced nothing on the two you did not anticipate,
 * which looks exactly like "this source does not have that track".
 */
internal object ProviderLyrics {

    fun parse(raw: String): List<LyricLineDto>? {
        val content = unescapeTtml(unwrap(raw) ?: return null)
        val lines = when {
            content.contains(Regex("""<tt(?:\s|>)""", RegexOption.IGNORE_CASE)) ||
                content.contains("http://www.w3.org/ns/ttml", ignoreCase = true) ->
                TtmlLyrics.parse(content)
            KaraokeLrc.looksLike(content) -> KaraokeLrc.parse(content)
            // Markup that is not TTML: a page, an error, something we cannot
            // read. Rendering it as lyrics would put HTML in front of a listener.
            content.trimStart().startsWith("<") -> emptyList()
            else -> EnhancedLrc.parse(content).ifEmpty { LrcLib.parseLrc(content) }
                .ifEmpty { plain(content) }
        }
        return lines.takeIf { found -> found.any { it.text.isNotBlank() } }
    }

    private fun plain(content: String): List<LyricLineDto> {
        // A refusal that arrived as prose. Reading it as lyrics would put
        // "lyrics not found" on screen in time with the music.
        if (content.contains(REFUSAL)) return emptyList()
        return content.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            // `[ar:…]`, `[ti:…]` — LRC metadata, not a line of the song.
            .filterNot { it.matches(ID_TAG) }
            .map { LyricLineDto(timeMs = 0L, text = it) }
            .toList()
    }

    private val REFUSAL = Regex("""(?i)\b(?:lyrics? (?:not found|unavailable)|error)\b""")
    private val ID_TAG = Regex("""\[[A-Za-z]+:.*]""")

    /** Providers sometimes wrap the same lyric string in one or two JSON envelopes. */
    internal fun unwrap(raw: String): String? {
        var value = raw.replace("\uFEFF", "").trim()
        if (value.startsWith("```")) {
            value = value.lineSequence().drop(1).toList()
                .let { if (it.lastOrNull()?.trim() == "```") it.dropLast(1) else it }
                .joinToString("\n").trim()
        }
        if (value.isBlank()) return null
        // Only *structured* JSON is unwrapped. A bare word parses as a lenient
        // JSON primitive, and treating that as an envelope made `unwrap` answer
        // null for the plainest possible payload — which is not a lyric, so the
        // caller had nothing at all. A body that is not an object or an array is
        // the content.
        val json = runCatching { lyricsJson.parseToJsonElement(value) }.getOrNull()
        if (json !is JsonObject && json !is JsonArray) return value
        return extract(json)?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun extract(element: JsonElement): String? = when (element) {
        JsonNull -> null
        is JsonPrimitive -> if (element.isString) {
            val text = element.content.trim()
            // A string that is itself JSON: the second envelope.
            val nested = runCatching { lyricsJson.parseToJsonElement(text) }.getOrNull()
            if (nested != null && nested !is JsonPrimitive) extract(nested) else text
        } else {
            null
        }
        is JsonArray -> element.mapNotNull(::extract).joinToString("\n").takeIf { it.isNotBlank() }
        is JsonObject -> {
            if (isRefusal(element)) return null
            CONTENT_KEYS.asSequence()
                .mapNotNull { element[it]?.let(::extract) }
                .firstOrNull()
                ?: (element["metadata"] as? JsonObject)?.let(::extract)
                ?: element["words"]?.let(::extract)
        }
    }

    /**
     * Whether this envelope is saying "I have nothing" rather than carrying
     * lyrics.
     *
     * A false positive costs one provider's turn in the race; a false negative
     * puts an error message on screen in time with the song.
     */
    private fun isRefusal(element: JsonObject): Boolean {
        if (element["isError"]?.toString() == "true") return true
        if (element["ok"]?.toString() == "false") return true
        val error = element["error"] ?: return false
        if (error is JsonNull) return false
        val text = error.toString()
        return text !in setOf("false", "\"\"", "null")
    }

    /**
     * Some hosts return the TTML escaped, so it arrives as a document *about* a
     * document. Unescaped only when it looks escaped — running the replacements
     * unconditionally would turn a lyric that genuinely reads "&amp;" into one
     * that reads "&".
     */
    private fun unescapeTtml(value: String): String = if (value.contains("&lt;tt", ignoreCase = true)) {
        value.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
            .replace("&#39;", "'").replace("&apos;", "'").replace("&amp;", "&")
    } else {
        value
    }

    /**
     * The keys the payload might be under, best first.
     *
     * Order matters: a response carrying both `ttml` and `plainLyrics` is
     * describing the same lyric twice, and the timed one is the one anybody
     * wants.
     */
    private val CONTENT_KEYS = listOf(
        "ttml", "ttmlContent", "lyrics", "lrc", "content", "text",
        "plainLyrics", "syncedLyrics", "line", "lines", "lyric",
        "data", "result", "response",
    )
}

/**
 * QQ/QRC and NetEase YRC: millisecond line and word ranges.
 *
 * A third format rather than a flavour of LRC: the line carries a *duration* as
 * well as a start, and each word carries its own, so the text has to be
 * reassembled from the timing annotations rather than read as a line with
 * brackets in it.
 */
internal object KaraokeLrc {

    private val LINE = Regex("""^\[(\d{1,8}),(\d{1,8})](.*)$""")
    private val PREFIX_WORD = Regex("""\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)([^()]*)""")
    private val SUFFIX_WORD = Regex("""([^()]*)\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)""")
    private val WORD_TIME = Regex("""\(\d{1,8},\d{1,8}(?:,\d{1,8})?\)""")
    private val CONTENT = Regex("""LyricContent\s*=\s*"([^"]*)"""", RegexOption.IGNORE_CASE)

    fun looksLike(raw: String): Boolean = lyricContent(raw).lineSequence().any { line ->
        LINE.matchEntire(line.trim())?.groupValues?.get(3)?.let {
            PREFIX_WORD.containsMatchIn(it) || SUFFIX_WORD.containsMatchIn(it)
        } == true
    }

    fun parse(raw: String): List<LyricLineDto> {
        val rows = lyricContent(raw).lineSequence().mapNotNull { source ->
            val match = LINE.matchEntire(source.trim()) ?: return@mapNotNull null
            val lineStart = match.groupValues[1].toLong()
            val lineDuration = match.groupValues[2].toLong()
            val body = match.groupValues[3]
            val prefixed = PREFIX_WORD.findAll(body).mapNotNull { word ->
                timedWord(word.groupValues[3], word.groupValues[1], word.groupValues[2])
            }.toList()
            val suffixed = SUFFIX_WORD.findAll(body).mapNotNull { word ->
                timedWord(word.groupValues[1], word.groupValues[2], word.groupValues[3])
            }.toList()
            // Both spellings turn up, sometimes in one file. The one that
            // accounts for more of the line's characters is the one that was
            // actually the words; the other is usually an annotation.
            val words = if (prefixed.sumOf { it.text.length } >= suffixed.sumOf { it.text.length }) {
                prefixed
            } else {
                suffixed
            }
            if (words.isEmpty()) return@mapNotNull null
            LyricLineDto(
                timeMs = minOf(lineStart, words.first().startMs),
                text = EnhancedLrc.decodeEntities(body.replace(WORD_TIME, "")).trim(),
                words = words,
                sungUntilMs = (lineStart + lineDuration).takeIf { lineDuration > 0 },
            )
        }.filter { it.text.isNotEmpty() }.sortedBy { it.timeMs }.toList()
        return rows.withInstrumentalGaps()
    }

    private fun timedWord(text: String, start: String, duration: String): LyricWordDto? {
        val clean = EnhancedLrc.decodeEntities(text).trim()
        if (clean.isEmpty()) return null
        val startMs = start.toLong()
        return LyricWordDto(startMs, startMs + duration.toLong(), clean)
    }

    /**
     * The lyric body, whether it is the whole answer or a field inside a script.
     *
     * NetEase ships the payload as a `LyricContent = "…"` assignment inside
     * something that is otherwise JavaScript, and reading the whole thing as
     * lyrics would put the assignment on screen.
     */
    private fun lyricContent(raw: String): String = CONTENT.find(raw)?.groupValues?.get(1)
        ?.replace("&quot;", "\"")?.replace("&apos;", "'")?.replace("&lt;", "<")
        ?.replace("&gt;", ">")?.replace("&amp;", "&") ?: raw
}

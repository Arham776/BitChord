package com.music.bitchord.data.lyrics

import com.music.bitchord.data.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/**
 * Races every enabled lyrics source in the user's order.
 *
 * [fetch] keeps the existing Swift callback (lines only).
 * [fetchAttributed] also reports which source won, for "Lyrics by {source}".
 */
object LyricsBridge {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun interface LyricsCallback {
        fun onResult(lines: List<LyricLineDto>)
    }

    /** Swift: show "Lyrics by {sourceLabel}". Empty [source] means embedded file lyrics. */
    fun interface AttributedLyricsCallback {
        fun onResult(source: String, sourceLabel: String, lines: List<LyricLineDto>)
    }

    fun fetch(title: String, artist: String, durationMs: Long, callback: LyricsCallback) {
        fetch(title, artist, durationMs, album = null, callback)
    }

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        callback: LyricsCallback,
    ) = fetch(title, artist, durationMs, album, videoId = null, callback)

    fun fetch(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        callback: LyricsCallback,
    ) = fetchAttributed(title, artist, durationMs, album, videoId, localPath = null) { _, _, lines ->
        callback.onResult(lines)
    }

    /**
     * Same race as [fetch], plus source attribution and an optional local file
     * to read embedded lyrics from first (downloaded/local tracks).
     */
    fun fetchAttributed(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        localPath: String?,
        callback: AttributedLyricsCallback,
    ) {
        scope.launch {
            val (source, lines) = runCatching {
                lookup(title, artist, durationMs, album, videoId, localPath)
            }.getOrElse { null to emptyList() }
            callback.onResult(source?.name.orEmpty(), source?.label.orEmpty(), lines)
        }
    }

    /** Read lyrics already tagged into a local/downloaded file. */
    fun fetchEmbedded(path: String, callback: LyricsCallback) {
        scope.launch {
            val lines = runCatching { EmbeddedLyrics.forPath(path) }.getOrNull().orEmpty()
            callback.onResult(lines)
        }
    }

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        videoId: String? = null,
    ): List<LyricLineDto> = lookup(title, artist, durationMs, album, videoId, localPath = null).second

    private suspend fun lookup(
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        videoId: String?,
        localPath: String?,
    ): Pair<LyricsSource?, List<LyricLineDto>> {
        if (!localPath.isNullOrBlank()) {
            EmbeddedLyrics.forPath(localPath)?.let { return null to it }
        }
        if (!AppSettings.syncedLyrics.value) return null to emptyList()
        val sources = AppSettings.lyricsSourcesSet()
        if (sources.isEmpty() || durationMs <= 0L) return null to emptyList()
        val found = LyricsRepository.lyrics(
            videoId = videoId.orEmpty(),
            title = title,
            artist = artist,
            durationMs = durationMs,
            album = album,
            sources = sources,
            order = AppSettings.lyricsSourceOrderList(),
            prioritizeSyllableSync = AppSettings.prioritizeSyllableSync.value,
        )
        return found?.source to found?.lines.orEmpty()
    }

    // ---- Translation -------------------------------------------------------

    /**
     * Translate the lyric into [targetLanguageTag].
     *
     * One call rather than an exposed [LyricsTranslation], because the answer is
     * three-valued and the host should not have to re-derive which: a
     * translation, "these are already in that language", or nothing. The last of
     * those is a normal outcome — an empty lyric, a failure, a language the
     * endpoint does not carry — and must not be reported as an error.
     */
    fun translate(
        trackId: String,
        linesJson: String,
        targetLanguageTag: String,
        callback: TranslationCallback,
    ) {
        scope.launch {
            val lines = decodeLines(linesJson)
            val result = if (lines.isEmpty()) {
                LyricsTranslation.Result.Unavailable
            } else {
                runCatching { LyricsTranslation.translate(trackId, lines, targetLanguageTag) }
                    .getOrElse { LyricsTranslation.Result.Unavailable }
            }
            when (result) {
                is LyricsTranslation.Result.Translated -> callback.onResult(
                    status = "translated",
                    document = encodeLines(result.lines),
                    sourceLanguage = result.sourceLanguage,
                    fromCache = result.fromCache,
                )
                is LyricsTranslation.Result.SameLanguage -> callback.onResult(
                    status = "same",
                    document = linesJson,
                    sourceLanguage = result.language,
                    fromCache = true,
                )
                LyricsTranslation.Result.Unavailable -> callback.onResult(
                    status = "unavailable", document = "", sourceLanguage = "", fromCache = false,
                )
            }
        }
    }

    /**
     * Put the lyric into Latin script.
     *
     * Distinct from translating, and reported distinctly: a Japanese lyric asked
     * for in English is a translation, and the same lyric asked for as romaji is
     * a pronunciation. Conflating the two produced requests nothing could answer.
     */
    fun romanize(
        trackId: String,
        linesJson: String,
        targetLanguageTag: String,
        callback: TranslationCallback,
    ) {
        scope.launch {
            val lines = decodeLines(linesJson)
            val result = if (lines.isEmpty()) {
                LyricsTranslation.RomanizationResult.Unavailable
            } else {
                runCatching { LyricsTranslation.romanize(trackId, lines, targetLanguageTag) }
                    .getOrElse { LyricsTranslation.RomanizationResult.Unavailable }
            }
            when (result) {
                is LyricsTranslation.RomanizationResult.Romanized -> callback.onResult(
                    status = "translated",
                    document = encodeLines(result.lines),
                    sourceLanguage = result.sourceLanguage,
                    fromCache = result.fromCache,
                )
                // Already Latin: not a failure, and not a translation either. The
                // host shows the original and says there was nothing to do.
                LyricsTranslation.RomanizationResult.AlreadyRomanized -> callback.onResult(
                    status = "same", document = linesJson, sourceLanguage = "", fromCache = true,
                )
                LyricsTranslation.RomanizationResult.Unavailable -> callback.onResult(
                    status = "unavailable", document = "", sourceLanguage = "", fromCache = false,
                )
            }
        }
    }

    /**
     * Every language the translate and romanise buttons offer.
     *
     * One document rather than two calls, because the host draws one picker and
     * the two lists differ; making it ask twice would mean it could render a
     * half-loaded list.
     */
    fun languagesJson(): String {
        val translate = TRANSLATION_LANGUAGES.joinToString(",", prefix = "[", postfix = "]") {
            """{"code":${quote(it.code)},"name":${quote(it.fallbackName)},"romanizable":false}"""
        }
        val romanize = ROMANIZATION_LANGUAGES.joinToString(",", prefix = "[", postfix = "]") {
            """{"code":${quote(it.code)},"name":${quote(it.fallbackName)},"romanizable":true}"""
        }
        return """{"translate":$translate,"romanize":$romanize}"""
    }

    fun clearTranslationCache() = TranslationCache.clear()

    private fun decodeLines(document: String): List<LyricLineDto> = runCatching {
        lyricsJson.decodeFromString(LyricLineList.serializer(), document).lines
    }.getOrDefault(emptyList())

    private fun encodeLines(lines: List<LyricLineDto>): String = runCatching {
        lyricsJson.encodeToString(LyricLineList.serializer(), LyricLineList(lines))
    }.getOrDefault(EMPTY_LINES)

    private fun quote(value: String): String = buildString {
        append('"')
        value.forEach { ch ->
            when {
                ch == '"' -> append("\\\"")
                ch == '\\' -> append("\\\\")
                ch == '\n' -> append("\\n")
                ch == '\r' -> append("\\r")
                ch == '\t' -> append("\\t")
                ch.code < 0x20 -> append("\\u").append(ch.code.toString(16).padStart(4, '0'))
                else -> append(ch)
            }
        }
        append('"')
    }
}

/** A lyric as it crosses the bridge. */
@Serializable
internal data class LyricLineList(val lines: List<LyricLineDto> = emptyList())

private const val EMPTY_LINES = """{"lines":[]}"""

/** The host-facing shape of a translation or a romanisation. */
interface TranslationCallback {
    /**
     * @param status `translated`, `same` (already in that language or already
     *   Latin) or `unavailable`. None of the three is an error.
     * @param document the lyric as a [LyricLineList]; empty when unavailable.
     * @param sourceLanguage what it was translated from, when known.
     * @param fromCache whether this came off disk rather than off the network —
     *   exposed so the host can say "already translated" rather than showing a
     *   spinner for something that is about to appear instantly.
     */
    fun onResult(
        status: String,
        document: String,
        sourceLanguage: String,
        fromCache: Boolean,
    )
}

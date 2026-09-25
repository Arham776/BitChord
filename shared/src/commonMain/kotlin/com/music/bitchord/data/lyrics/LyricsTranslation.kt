package com.music.bitchord.data.lyrics

import com.music.bitchord.data.http.Http
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Lightweight, on-demand lyric translation and romanisation.
 *
 * Translation models are deliberately not installed on the device. A model for
 * every app language would cost tens of megabytes each; translated lyric text is
 * normally only a few kilobytes. Requests are batched and the compact result is
 * kept in a bounded cache, so the feature can never grow without limit.
 *
 * ## What the batching is protecting
 *
 * A lyric is a list of short strings, and sending them one at a time would be
 * forty requests a song. Instead they are packed into one payload with a private
 * -use marker between each, and the markers are what the answers are split on.
 *
 * The markers are private-use code points rather than something visible like
 * `[3]` because the payload is translated on the way through, and a visible
 * delimiter is a thing a translation engine will helpfully renumber, reword, or
 * drop. Input Tools rewrites ASCII digits into the destination script on the
 * romanisation retry path, so a numeric marker would not survive that either.
 */
object LyricsTranslation {

    sealed interface Result {
        /**
         * Translated lines, and what they were translated from.
         *
         * [fromCache] is exposed rather than hidden because a translation that
         * appears instantly and one that takes a second read very differently,
         * and a listener watching for the spinner deserves to know which they got.
         */
        data class Translated(
            val lines: List<LyricLineDto>,
            val sourceLanguage: String,
            val fromCache: Boolean,
        ) : Result

        /** The lyrics are already in the language asked for; nothing to do. */
        data class SameLanguage(val language: String) : Result

        /** Nothing was produced — a failure, an empty lyric, or no such language. */
        data object Unavailable : Result
    }

    sealed interface RomanizationResult {
        data class Romanized(
            val lines: List<LyricLineDto>,
            val sourceLanguage: String,
            val fromCache: Boolean,
        ) : RomanizationResult

        /** Already in Latin script, so there was nothing to do. */
        data object AlreadyRomanized : RomanizationResult

        data object Unavailable : RomanizationResult
    }

    private const val ENDPOINT = "https://translate.googleapis.com/translate_a/single"
    private const val INPUT_TOOLS_ENDPOINT = "https://inputtools.google.com/request"

    /**
     * Bumped when the *policy* changes rather than when the endpoint does.
     *
     * Version 3 invalidated answers cached before the Latin-script retry existed;
     * otherwise a song that once came back untranslated would never take the
     * repaired path after the app is updated.
     */
    private const val CACHE_VERSION = 4

    private const val MAX_BATCH_CHARS = 3_500
    private const val MAX_PARALLEL_REQUESTS = 2
    private const val TRANSLATION_AGENT = "BitChord/1.6.1"

    private val markerRegex = Regex("[^]*")
    private val json = Json { ignoreUnknownKeys = true }

    private data class TextSlot(
        val lineIndex: Int,
        val background: Boolean,
        val text: String,
        val sectionHeader: Boolean,
    )

    private data class Batch(
        val slots: List<TextSlot>,
        val payload: String,
    )

    private data class BatchAnswer(
        val translations: List<String>,
        val sourceLanguage: String,
        val sourceWeight: Int,
    )

    // ---- Translation -------------------------------------------------------

    suspend fun translate(
        trackId: String,
        lines: List<LyricLineDto>,
        targetLanguageTag: String,
    ): Result {
        // Sent as given rather than reduced to a base language: zh-CN and zh-TW
        // are the same language in two scripts, and canonicalising either to "zh"
        // hands back Simplified whichever one was asked for. The narrowing is
        // still done, but only where it belongs — in [sameLanguage], which is
        // asking a different question.
        val target = targetLanguageTag.trim()
        if (target.isBlank() || lines.isEmpty()) return Result.Unavailable

        val slots = flatten(lines)
        if (slots.isEmpty()) return Result.Unavailable
        val cacheKey = cacheKey(trackId, target, slots)
        val cached = TranslationCache.get(cacheKey)
        if (cached != null && cached.version == CACHE_VERSION && cached.texts.size == slots.size) {
            return if (sameLanguage(cached.sourceLanguage, target)) {
                Result.SameLanguage(cached.sourceLanguage)
            } else {
                Result.Translated(
                    lines = rebuild(lines, slots, cached.texts),
                    sourceLanguage = cached.sourceLanguage,
                    fromCache = true,
                )
            }
        }

        val batches = batches(slots)
        val answers = coroutineScope {
            // Two short requests at a time keeps a long lyric fast without
            // competing with playback for every connection in the pool.
            batches.chunked(MAX_PARALLEL_REQUESTS).flatMap { group ->
                group.map { batch -> async { requestBatch(batch, target) } }.awaitAll()
            }
        }
        if (answers.any { it == null }) return Result.Unavailable
        val complete = answers.filterNotNull()
        val source = dominantSource(complete)
        if (source.isBlank()) return Result.Unavailable

        var translated = complete.flatMap { it.translations }
        if (translated.size != slots.size) return Result.Unavailable

        // Google's ordinary auto-detection understands many Latin-script
        // Hindi/Urdu/Punjabi lyrics, but its NMT occasionally returns whole
        // phrases unchanged. If a sizeable part of a Latin-script source survived
        // untouched, use Input Tools to restore the detected language's native
        // script and translate *that*. Keep the first answer unless the retry
        // actually transforms more of the song, so names and genuinely bilingual
        // lyrics do not get worse merely because they contain Latin text.
        if (
            !sameLanguage(source, target) &&
            predominantlyLatin(slots) &&
            unchangedWeight(slots, translated) * 3 >= slots.sumOf { it.text.length }
        ) {
            val retried = retryRomanizedTranslation(batches, source, target)
            if (
                retried != null &&
                retried.size == slots.size &&
                unchangedWeight(slots, retried) < unchangedWeight(slots, translated)
            ) {
                translated = retried
            }
        }

        TranslationCache.put(
            cacheKey,
            CachedTranslation(
                version = CACHE_VERSION,
                sourceLanguage = source,
                targetLanguage = target,
                texts = translated,
            ),
        )

        return if (sameLanguage(source, target)) {
            Result.SameLanguage(source)
        } else {
            Result.Translated(
                lines = rebuild(lines, slots, translated),
                sourceLanguage = source,
                fromCache = false,
            )
        }
    }

    // ---- Romanisation ------------------------------------------------------

    suspend fun romanize(
        trackId: String,
        lines: List<LyricLineDto>,
        targetLanguageTag: String,
    ): RomanizationResult {
        if (lines.isEmpty()) return RomanizationResult.Unavailable
        val slots = flatten(lines)
        if (slots.isEmpty()) return RomanizationResult.Unavailable
        // The cheap all-Latin test, before any request: the overwhelming majority
        // of lyrics are already in a Latin script and this is the whole no-op.
        if (!slots.any { slot -> slot.text.any { isNonLatinLetter(it) } }) {
            return RomanizationResult.AlreadyRomanized
        }

        // Romanisation always ends in Latin script. The translation destination
        // is still sent as `tl` because the web endpoint requires it, but it is
        // deliberately excluded from this cache key: changing "translate to"
        // cannot change how the source language is pronounced.
        val cacheKey = cacheKey(trackId, "romanize", slots)
        val cached = TranslationCache.get(cacheKey)
        if (cached != null && cached.version == CACHE_VERSION && cached.texts.size == slots.size) {
            return RomanizationResult.Romanized(
                lines = rebuild(lines, slots, cached.texts),
                sourceLanguage = cached.sourceLanguage,
                fromCache = true,
            )
        }

        val target = targetLanguageTag.trim().ifBlank { "en" }
        val batches = batches(slots)
        val answers = coroutineScope {
            batches.chunked(MAX_PARALLEL_REQUESTS).flatMap { group ->
                group.map { batch -> async { requestRomanizationBatch(batch, target) } }.awaitAll()
            }
        }
        if (answers.any { it == null }) return RomanizationResult.Unavailable
        val complete = answers.filterNotNull()
        val source = dominantSource(complete)
        val romanized = complete.flatMap { it.translations }
        if (source.isBlank() || romanized.size != slots.size) {
            return RomanizationResult.Unavailable
        }
        if (unchangedWeight(slots, romanized) == slots.sumOf { it.text.length }) {
            // Non-Latin input reached this point, so an unchanged response is an
            // unsupported or failed romanisation rather than an already-Latin
            // lyric. The fast check above handles the real no-op case.
            return RomanizationResult.Unavailable
        }

        TranslationCache.put(
            cacheKey,
            CachedTranslation(
                version = CACHE_VERSION,
                sourceLanguage = source,
                targetLanguage = "Latn",
                texts = romanized,
            ),
        )
        return RomanizationResult.Romanized(
            lines = rebuild(lines, slots, romanized),
            sourceLanguage = source,
            fromCache = false,
        )
    }

    // ---- Slot extraction ---------------------------------------------------

    /**
     * Every run of text that has to survive the round trip, as a flat list.
     *
     * Flat because the batching, the marker round trip and the alignment are all
     * simpler over a list of strings than over a tree, and the structure is put
     * back by [rebuild] against the line index each slot carries.
     */
    private fun flatten(lines: List<LyricLineDto>): List<TextSlot> = buildList {
        lines.forEachIndexed { index, line ->
            if (line.text.isNotBlank()) {
                val header = isSectionHeader(line.text)
                add(
                    TextSlot(
                        lineIndex = index,
                        background = false,
                        // The brackets are packaging, not words. Translated
                        // headers read better without them and the endpoint
                        // would translate them as literal punctuation.
                        text = if (header) {
                            line.text.removePrefix("[").removeSuffix("]").trim()
                        } else {
                            line.text
                        },
                        sectionHeader = header,
                    ),
                )
            }
            line.background?.takeIf { it.text.isNotBlank() }?.let { background ->
                add(TextSlot(index, background = true, background.text, sectionHeader = false))
            }
        }
    }

    /** A bracketed line that names a section rather than saying anything. */
    internal fun isSectionHeader(text: String): Boolean {
        val trimmed = text.trim()
        if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return false
        val inner = trimmed.removePrefix("[").removeSuffix("]").trim()
        // More than one line inside the brackets is a stanza, not a header.
        if (inner.isEmpty() || inner.contains('\n')) return false
        return SECTION_HEADER.matches(inner)
    }

    private val SECTION_HEADER =
        Regex("""(?i)\s*(?:verse|chorus|intro|outro|bridge|hook|refrain|prechorus|pre-chorus|interlude|instrumental|breakdown|drop|tag)\b.*""")

    // ---- Batching ----------------------------------------------------------

    private fun batches(slots: List<TextSlot>): List<Batch> {
        val result = mutableListOf<Batch>()
        var current = mutableListOf<TextSlot>()
        var length = 0

        fun flush() {
            if (current.isEmpty()) return
            result += Batch(current.toList(), payload(current))
            current = mutableListOf()
            length = 0
        }

        slots.forEach { slot ->
            val added = slot.text.length + if (current.isEmpty()) 0 else 8
            if (current.isNotEmpty() && length + added > MAX_BATCH_CHARS) flush()
            current += slot
            length += added
        }
        flush()
        return result
    }

    private fun payload(slots: List<TextSlot>): String = buildString {
        slots.forEachIndexed { index, slot ->
            if (index > 0) append('\n').append(marker(index)).append('\n')
            append(slot.text)
        }
    }

    /**
     * A private-use delimited, zero-padded index.
     *
     * Padded because the answer is split on the marker and then zipped with the
     * slots in order — a variable-width index would be fine for that, but a
     * fixed width means a marker that came back mangled is still recognisable as
     * a marker rather than being mistaken for lyric text.
     */
    private fun marker(index: Int): String = "${index.toString().padStart(4, '0')}"

    // ---- Requests ----------------------------------------------------------

    private suspend fun requestBatch(
        batch: Batch,
        target: String,
        sourceLanguage: String = "auto",
    ): BatchAnswer? {
        val body = postForm(ENDPOINT, mapOf(
            "client" to "dict-chrome-ex",
            "sl" to sourceLanguage,
            "tl" to target,
            "dt" to "t",
            "q" to batch.payload,
        )) ?: return null
        return runCatching {
            val root = json.parseToJsonElement(body).jsonArray
            val translatedBody = root[0].jsonArray.joinToString(separator = "") { segment ->
                segment.jsonArray.getOrNull(0)?.jsonPrimitive?.contentOrNull.orEmpty()
            }
            val source = root.getOrNull(2)?.jsonPrimitive?.contentOrNull.orEmpty()
            val parts = translatedBody.split(markerRegex).map { it.trim() }
            if (parts.size != batch.slots.size || parts.any { it.isBlank() }) return null
            BatchAnswer(parts, source, batch.payload.length)
        }.getOrNull()
    }

    private suspend fun requestRomanizationBatch(batch: Batch, target: String): BatchAnswer? {
        val body = postForm(ENDPOINT, mapOf(
            "client" to "dict-chrome-ex",
            "sl" to "auto",
            "tl" to target,
            "dt" to "rm",
            "q" to batch.payload,
        )) ?: return null
        return runCatching {
            val root = json.parseToJsonElement(body).jsonArray
            // Index 3, not 0: `dt=rm` puts the romanised form in its own slot and
            // leaves the translated one in 0.
            val romanizedBody = root[0].jsonArray.joinToString(separator = "") { segment ->
                segment.jsonArray.getOrNull(3)?.jsonPrimitive?.contentOrNull.orEmpty()
            }
            val source = root.getOrNull(2)?.jsonPrimitive?.contentOrNull.orEmpty()
            val parts = romanizedBody.split(markerRegex).map { it.trim() }
            if (source.isBlank() || parts.size != batch.slots.size || parts.any { it.isBlank() }) {
                return null
            }
            BatchAnswer(parts, source, batch.payload.length)
        }.getOrNull()
    }

    /**
     * The second attempt, for a source that auto-detection got wrong.
     *
     * Input Tools restores the language's own script, and that is then translated
     * with the language named rather than auto-detected — so the retry is not
     * "try again", it is a different question with a known answer.
     */
    private suspend fun retryRomanizedTranslation(
        batches: List<Batch>,
        sourceLanguage: String,
        target: String,
    ): List<String>? = coroutineScope {
        val source = canonicalLanguage(sourceLanguage)
        if (source.isBlank() || source == "en") return@coroutineScope null
        val answers = batches.chunked(MAX_PARALLEL_REQUESTS).flatMap { group ->
            group.map { batch ->
                async {
                    val nativePayload = requestNativeScript(batch.payload, source) ?: return@async null
                    requestBatch(batch.copy(payload = nativePayload), target, source)
                }
            }.awaitAll()
        }
        if (answers.any { it == null }) null else answers.filterNotNull().flatMap { it.translations }
    }

    private suspend fun requestNativeScript(text: String, sourceLanguage: String): String? {
        val body = postForm(INPUT_TOOLS_ENDPOINT, mapOf(
            "text" to text,
            "itc" to "$sourceLanguage-t-i0-und",
            "num" to "1",
            "cp" to "0",
            "cs" to "1",
            "ie" to "utf-8",
            "oe" to "utf-8",
        )) ?: return null
        return runCatching {
            val root = json.parseToJsonElement(body).jsonArray
            if (root.getOrNull(0)?.jsonPrimitive?.contentOrNull != "SUCCESS") return null
            root[1].jsonArray[0].jsonArray[1].jsonArray[0].jsonPrimitive.contentOrNull
                ?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private suspend fun postForm(url: String, form: Map<String, String>): String? = try {
        withContext(Dispatchers.Default) {
            Http.postForm(url, form, headers = mapOf("User-Agent" to TRANSLATION_AGENT))
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    // ---- Judging the answer ------------------------------------------------

    /** The language most of the lyric is in, by character weight. */
    private fun dominantSource(answers: List<BatchAnswer>): String = answers
        .groupBy { canonicalLanguage(it.sourceLanguage) }
        .maxByOrNull { (_, values) -> values.sumOf { it.sourceWeight } }
        ?.key
        .orEmpty()

    private fun predominantlyLatin(slots: List<TextSlot>): Boolean {
        var latin = 0
        var other = 0
        for (slot in slots) {
            for (ch in slot.text) {
                if (!isLetter(ch)) continue
                if (isLatinLetter(ch)) latin++ else other++
            }
        }
        return latin > 0 && latin >= other * 4
    }

    /**
     * How many characters came back untouched.
     *
     * Compared case-insensitively and whitespace-collapsed, because a translation
     * engine will happily "correct" the capitalisation and spacing of a line it
     * did not actually translate, and counting that as progress would defeat the
     * check it exists for.
     */
    private fun unchangedWeight(slots: List<TextSlot>, transformed: List<String>): Int =
        slots.zip(transformed).sumOf { (slot, text) ->
            if (comparable(slot.text) == comparable(text)) slot.text.length else 0
        }

    private fun comparable(text: String): String = text
        .trim()
        .lowercase()
        .replace(WHITESPACE, " ")

    private val WHITESPACE = Regex("""\s+""")

    /**
     * Whether [a] and [b] are the same language, by base tag.
     *
     * Narrowing to a base tag is right *here* and wrong when sending, and the
     * difference is the script: a request must carry `zh-TW` rather than `zh` or
     * it comes back Simplified. So this comparison is about whether there is
     * anything to do at all, and `zh-CN` against `zh-TW` is "nothing to do" —
     * the words are already Chinese.
     *
     * The consequence, stated because it is a real limitation rather than an
     * accident: a listener with a Simplified lyric who asks for Traditional is
     * told it is already Chinese and gets no script conversion. Converting
     * between scripts is a different request from translating, and this does not
     * do it.
     */
    internal fun sameLanguage(a: String, b: String): Boolean {
        val left = canonicalLanguage(a)
        val right = canonicalLanguage(b)
        return left.isNotBlank() && left == right
    }

    /**
     * The base language of a tag, with the legacy codes the endpoint still uses.
     *
     * Hand-rolled rather than via `Locale.forLanguageTag`, which is not in common
     * code — and the mapping is small enough that a table is clearer than the
     * locale data it would be reading.
     */
    internal fun canonicalLanguage(tag: String): String {
        val base = tag.trim().replace('_', '-').substringBefore('-').lowercase()
        return when (base) {
            "iw" -> "he"
            "in" -> "id"
            "ji" -> "yi"
            "mo" -> "ro"
            // The endpoint answers "no" for Norwegian Bokmål and writes it "no".
            "nb", "nn" -> "no"
            else -> base
        }
    }

    // ---- Rebuilding --------------------------------------------------------

    /**
     * Put the translated strings back into the shape they came from.
     *
     * Every structural property of the original is preserved — the timings, the
     * gaps, which line is a background vocal — and only the *text* changes. That
     * is what makes a translated lyric still line up with the music.
     */
    private fun rebuild(
        original: List<LyricLineDto>,
        slots: List<TextSlot>,
        translated: List<String>,
    ): List<LyricLineDto> {
        val byLine = slots.zip(translated).groupBy { it.first.lineIndex }
        return original.mapIndexed { index, line ->
            val entries = byLine[index].orEmpty()
            val lead = entries.firstOrNull { !it.first.background }
            val backing = entries.firstOrNull { it.first.background }
            val leadText = lead?.let { (slot, text) ->
                if (slot.sectionHeader) "[$text]" else text
            } ?: line.text
            line.copy(
                text = leadText,
                words = retimeWords(line, leadText),
                background = line.background?.let { source ->
                    val text = backing?.second ?: source.text
                    source.copy(text = text, words = retimeWords(source, text))
                },
            )
        }
    }

    /**
     * One word spanning the source's own vocal bounds, over the new text.
     *
     * Deliberately *not* a per-word sweep of the new text. The source timings are
     * a performance, not a measurement of this string: distributing them across
     * a translation by character count would put a hold in the middle of a word
     * and animate syllables that were never sung. The line still lights up across
     * exactly the span the original vocal occupied, which is true of both.
     */
    private fun retimeWords(source: LyricLineDto, translated: String): List<LyricWordDto> {
        if (source.words.isEmpty()) return emptyList()
        if (translated.isEmpty()) return emptyList()
        val start = source.words.first().startMs
        val end = source.words.last().endMs
        if (end <= start) return emptyList()
        return listOf(LyricWordDto(start, end, translated))
    }

    // ---- Cache key ---------------------------------------------------------

    /**
     * A key covering the track, the target *and* the text.
     *
     * The text is in the key because the same track can be asked about with
     * different lyrics — a translation of a translation, a re-fetch that found a
     * better sync — and a key without it would serve the first answer to the
     * second question.
     */
    private fun cacheKey(trackId: String, target: String, slots: List<TextSlot>): String {
        val fingerprint = slots.joinToString(" ") { "${it.background}:${it.text}" }
        return "$CACHE_VERSION|$trackId|$target|${fingerprint.length}|${fingerprint.hashCode()}"
    }
}

// MARK: - Script detection

/**
 * Whether [ch] is a letter in the Latin script.
 *
 * Written out as ranges because `Character.UnicodeScript` is JVM-only and this has
 * to build for Kotlin/Native. The ranges are the Latin blocks proper plus the
 * ASCII letters; a character outside them is either another script or a symbol,
 * and treating a symbol as non-Latin is the safe direction — it can only make
 * [predominantlyLatin] more cautious, never less.
 */
internal fun isLatinLetter(ch: Char): Boolean {
    val code = ch.code
    return when (code) {
        in 'a'.code..'z'.code -> true
        in 'A'.code..'Z'.code -> true
        in 0x00C0..0x00FF -> true // Latin-1 Supplement: À-ÿ
        in 0x0100..0x017F -> true // Latin Extended-A
        in 0x0180..0x024F -> true // Latin Extended-B
        in 0x1E00..0x1EFF -> true // Latin Extended Additional
        in 0x2C60..0x2C7F -> true // Latin Extended-C
        in 0xA720..0xA7FF -> true // Latin Extended-D
        in 0xAB30..0xAB6F -> true // Latin Extended-E
        in 0x0250..0x02AF -> isIpaExtension(code)
        in 0x1D00..0x1D7F -> isIpaExtension(code) // phonetic extensions
        else -> false
    }
}

/** The IPA block, which is Latin-derived but a letter in its own right. */
private fun isIpaExtension(code: Int): Boolean =
    code in 0x0250..0x02AF || (code in 0x1D00..0x1D7F && code != 0x1D7E && code != 0x1D7F)

/** Whether [ch] is a letter at all, in any script. */
internal fun isLetter(ch: Char): Boolean = ch.isLetter()

/**
 * Whether [ch] is a letter that is *not* Latin.
 *
 * What the romanisation entry point asks, and it is deliberately the complement
 * of [isLatinLetter] over letters rather than a positive list of scripts: a
 * script not enumerated here still counts as non-Latin, which is the direction
 * that makes "there is something to romanise" true more often than not.
 */
internal fun isNonLatinLetter(ch: Char): Boolean = ch.isLetter() && !isLatinLetter(ch)

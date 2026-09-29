package com.music.bitchord.data.lyrics

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import com.music.bitchord.data.settings.AppSettings
import kotlin.math.abs

/**
 * Word-timed lyrics via paxsenix, a proxy in front of Apple Music's catalogue and
 * — with a key — in front of two others.
 *
 * ## The two halves
 *
 * The public half needs no configuration: it searches Apple's own catalogue for
 * the recording and fetches its TTML. That is the original behaviour and it is
 * what [lyrics] does, so a listener with no key configured loses nothing.
 *
 * The authenticated half is three further routes — `spotify`, `musixmatch` and a
 * general `lrcget` — that reach catalogues Apple's does not carry. They are
 * opt-in because they need a key the listener supplies, and an app that quietly
 * had one would be sending somebody else's credential to a server they never
 * chose. With no key set, every one of them is a miss and says so.
 */
object PaxSenix {

    private const val PROXY = "https://lyrics.paxsenix.org"
    private const val API = "https://api.paxsenix.org"
    private const val MINIMUM_MATCH_SCORE = 10
    private const val APPLE_SEARCH = "https://amp-api.music.apple.com/v1/catalog/us/search"

    private val tokenMutex = Mutex()
    @kotlin.concurrent.Volatile private var cachedToken: String? = null

    /**
     * The key for the authenticated routes, or empty.
     *
     * Read from the setting on every call rather than cached. An earlier version
     * held a copy, which had to be pushed into this object whenever the setting
     * changed — and nothing did that at launch, so a key set in a previous session
     * was simply not there: every authenticated route was a miss and the settings
     * screen said they were configured. There is no way for a stored value and
     * this object to disagree now, because there is only one copy.
     */
    private val apiKey: String
        get() = AppSettings.paxSenixApiKey.value

    /** Whether the authenticated routes can be tried at all. */
    val hasApiKey: Boolean get() = apiKey.isNotBlank()

    suspend fun lyrics(
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
    ): List<LyricLineDto>? {
        val seconds = (durationMs / 1000).toInt()
        val query = listOfNotNull(
            title.forLyricsSearch(),
            artist.artistForLyricsSearch().takeIf { it.isNotBlank() },
        )
            .joinToString(" ")
        val results = search(query) ?: return null
        // The floor is the whole point and this path did not have it.
        //
        // Upstream routes its keyless search through `bestCandidate`, which
        // refuses anything below `MINIMUM_MATCH_SCORE`. Without the floor a
        // candidate that matches *neither* the title nor the artist scores zero
        // and is still returned as long as its length lands within the
        // tolerance — the wrong song's lyrics, correctly timed, which is the
        // hardest kind of wrong to notice. It bites hardest where a name match
        // was never going to succeed, which is exactly the unfamiliar and
        // non-Latin catalogue.
        val best = results
            .mapNotNull { track ->
                val score = LyricsMatching.candidateScore(
                    wantedTitle = title,
                    wantedArtist = artist,
                    wantedDurationMs = durationMs,
                    candidateTitle = track.attributes.name,
                    candidateArtist = track.attributes.artistName,
                    candidateDurationMs = track.attributes.durationInMillis ?: 0L,
                ) ?: return@mapNotNull null
                track to score
            }
            .filter { it.second >= MINIMUM_MATCH_SCORE }
            .maxByOrNull { it.second }
            ?.first
            ?: return null

        return fetchLyrics(best.id)
    }

    private suspend fun search(query: String): List<AppleTrack>? {
        val token = getToken() ?: return null
        val body = lyricsGetAuthorized(
            APPLE_SEARCH,
            token,
            query = mapOf(
                "term" to query,
                "types" to "songs",
                "limit" to "10",
                "l" to "en-US",
            ),
        ) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(AppleSearchResponse.serializer(), body) }.getOrNull()
        return response?.results?.songs?.data
    }

    private suspend fun fetchLyrics(appleId: String): List<LyricLineDto>? {
        val body = lyricsGet("$PROXY/apple-music/lyrics", query = mapOf("id" to appleId)) ?: return null
        val response = runCatching { lyricsJson.decodeFromString(LyricsResponse.serializer(), body) }.getOrNull()
            ?: return null

        response.ttmlContent?.takeIf { it.isNotBlank() }?.let { ttml ->
            TtmlLyrics.parse(ttml).takeIf { it.isNotEmpty() }?.let { return it }
        }
        response.elrcMultiPerson?.takeIf { it.isNotBlank() }?.let { elrc ->
            EnhancedLrc.parse(elrc).takeIf { it.isNotEmpty() }?.let { return it }
        }
        response.elrc?.takeIf { it.isNotBlank() }?.let { elrc ->
            EnhancedLrc.parse(elrc).takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    private suspend fun getToken(): String? = cachedToken ?: tokenMutex.withLock {
        cachedToken ?: scrapeToken()?.also { cachedToken = it }
    }

    private suspend fun scrapeToken(): String? {
        val home = lyricsGet("https://music.apple.com/us/new") ?: return null
        val scriptPath = INDEX_JS.find(home)?.value ?: return null
        val script = lyricsGet("https://music.apple.com$scriptPath") ?: return null
        return TOKEN.find(script)?.value
    }

    @Serializable
    private data class AppleSearchResponse(val results: Results = Results())

    @Serializable
    private data class Results(val songs: Songs? = null)

    @Serializable
    private data class Songs(val data: List<AppleTrack> = emptyList())

    @Serializable
    private data class AppleTrack(val id: String, val attributes: Attributes)

    @Serializable
    private data class Attributes(
        val name: String,
        val artistName: String,
        @SerialName("durationInMillis") val durationInMillis: Long? = null,
    )

    @Serializable
    private data class LyricsResponse(
        val ttmlContent: String? = null,
        val elrc: String? = null,
        val elrcMultiPerson: String? = null,
    )

    // ---- Authenticated routes ----------------------------------------------

    /**
     * Spotify's own lyrics, through the proxy.
     *
     * Falls back to the general route rather than reporting a miss, because a
     * Spotify track id is found by name and the general route searches a wider
     * set — so the fallback is a second attempt at the same question by a
     * different route, not a different question.
     */
    suspend fun spotifyLyrics(
        title: String,
        artist: String,
        durationMs: Long,
    ): List<LyricLineDto>? {
        if (!hasApiKey) return null
        val id = searchTrackId("spotify/search", title, artist, durationMs)
            ?: return genericAuthenticatedLyrics(title, artist, durationMs)
        val body = apiBody("$API/lyrics/spotify", mapOf("id" to id)) ?: return null
        return parseResponse(body) ?: genericAuthenticatedLyrics(title, artist, durationMs)
    }

    /** Musixmatch's own lyrics, through the proxy. No id step — it matches on a name. */
    suspend fun musixmatchLyrics(
        title: String,
        artist: String,
        durationMs: Long,
    ): List<LyricLineDto>? {
        if (!hasApiKey) return null
        val query = mapOf(
            "t" to title,
            "a" to artist,
            "d" to (durationMs / 1000).toString(),
        )
        val body = apiBody("$API/lyrics/musixmatch", query) ?: return null
        return parseResponse(body) ?: genericAuthenticatedLyrics(title, artist, durationMs)
    }

    /**
     * The general endpoint, which searches rather than answering.
     *
     * Asking it for "the lyrics of this song" returns every candidate the search
     * found, each with its own timestamps. Parsing that array as one document
     * concatenates them all and makes each song's clock restart at zero, which
     * appears on screen as repeated lines that cannot stay in sync. So one
     * recording is chosen first — see [parseLrcGet].
     */
    private suspend fun genericAuthenticatedLyrics(
        title: String,
        artist: String,
        durationMs: Long,
    ): List<LyricLineDto>? {
        val body = apiBody("$API/lyrics/lrcget", mapOf("q" to "$title $artist"))
            ?: return null
        return parseLrcGet(body, title, artist, durationMs)
    }

    private suspend fun searchTrackId(
        path: String,
        title: String,
        artist: String,
        durationMs: Long,
    ): String? {
        val body = apiBody("$API/$path", mapOf("q" to "$title $artist")) ?: return null
        val root = runCatching { lyricsJson.parseToJsonElement(body) }.getOrNull() ?: return null
        return bestCandidate(root, title, artist, durationMs)?.id
    }

    /**
     * One recording out of a search result, and only if it is good enough.
     *
     * The floor matters: a search for one song routinely returns the same title by
     * a different artist, and taking the best of a bad set is still bad. Below the
     * floor the answer is a miss, which is true.
     */
    private fun bestCandidate(
        root: JsonElement,
        title: String,
        artist: String,
        durationMs: Long,
    ): Candidate? {
        val candidates = mutableListOf<Candidate>()
        root.collectCandidates(candidates)
        return candidates
            .mapNotNull { candidate ->
                candidate.score(title, artist, durationMs)?.let { candidate to it }
            }
            .maxByOrNull { it.second }
            ?.takeIf { it.second >= MINIMUM_MATCH_SCORE }
            ?.first
    }

    /**
     * Pick one document out of a search result.
     *
     * Metadata first, because a document that names the right song is worth more
     * than one that merely runs for the right length. Duration second, then timed
     * lines, then word-timed ones — the last because a word-timed answer is
     * strictly better than the same answer line-timed.
     */
    internal fun parseLrcGet(
        raw: String,
        title: String,
        artist: String,
        durationMs: Long,
    ): List<LyricLineDto>? {
        val root = runCatching { lyricsJson.parseToJsonElement(raw) }.getOrNull() ?: return null
        val documents = (root as? JsonObject)
            ?.get("lyrics") as? JsonArray
        if (documents == null || documents.isEmpty()) return parseResponse(raw)

        return documents.mapNotNull { document ->
            val lines = parseResponse(document.toString()) ?: return@mapNotNull null
            val metadataScore = (document as? JsonObject)
                ?.lyricCandidateScore(title, artist, durationMs) ?: return@mapNotNull null
            ParsedDocument(lines, metadataScore, durationDistance(lines, durationMs))
        }.maxWithOrNull(
            compareBy<ParsedDocument> { it.metadataScore }
                .thenBy { -it.durationDistanceMs }
                .thenBy { document -> document.lines.count { it.timeMs > 0L } }
                .thenBy { document -> document.lines.count { it.isWordSynced } },
        )?.lines
    }

    private fun durationDistance(lines: List<LyricLineDto>, durationMs: Long): Long {
        if (durationMs <= 0L) return 0L
        val last = lines.maxOfOrNull { line ->
            maxOf(line.timeMs, line.sungUntilMs ?: 0L, line.words.maxOfOrNull { it.endMs } ?: 0L)
        } ?: return Long.MAX_VALUE
        return abs(last - durationMs)
    }

    private fun JsonObject.lyricCandidateScore(
        title: String,
        artist: String,
        durationMs: Long,
    ): Int? {
        val details = this["attributes"] as? JsonObject ?: this
        return Candidate(
            id = details.firstString(ID_KEYS).orEmpty(),
            title = details.firstString(TITLE_KEYS).orEmpty(),
            artist = details.firstString(ARTIST_KEYS) ?: details.artistNames().orEmpty(),
            durationMs = details.firstLong(DURATION_KEYS).toDurationMs(),
        ).score(title, artist, durationMs)
    }

    private fun JsonElement.collectCandidates(
        into: MutableList<Candidate>,
    ) {
        when (this) {
            is JsonArray -> forEach { it.collectCandidates(into) }
            is JsonObject -> {
                toCandidate()?.let(into::add)
                values.forEach { it.collectCandidates(into) }
            }
            else -> Unit
        }
    }

    private fun JsonObject.toCandidate(): Candidate? {
        val details = this["attributes"] as? JsonObject ?: this
        val id = firstString(ID_KEYS) ?: details.firstString(ID_KEYS) ?: return null
        val title = details.firstString(TITLE_KEYS) ?: return null
        val artist = details.firstString(ARTIST_KEYS) ?: details.artistNames().orEmpty()
        return Candidate(id, title, artist, details.firstLong(DURATION_KEYS).toDurationMs())
    }

    private fun JsonObject.artistNames(): String? =
        when (val artists = this["artists"] ?: this["artist"]) {
            is JsonPrimitive -> artists.contentOrNull
            is JsonObject ->
                artists.firstString(listOf("name", "artistName", "title"))
            is JsonArray -> artists.mapNotNull { entry ->
                when (entry) {
                    is JsonPrimitive -> entry.contentOrNull
                    is JsonObject ->
                        entry.firstString(listOf("name", "artistName", "title"))
                    else -> null
                }
            }.joinToString(", ").takeIf { it.isNotEmpty() }
            else -> null
        }

    private fun JsonObject.firstString(keys: List<String>): String? =
        keys.firstNotNullOfOrNull { key ->
            (this[key] as? JsonPrimitive)
                ?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        }

    private fun JsonObject.firstLong(keys: List<String>): Long? =
        keys.firstNotNullOfOrNull { key ->
            (this[key] as? JsonPrimitive)
                ?.let { it.contentOrNull?.toLongOrNull() ?: it.longOrNull }
        }

    private fun Long?.toDurationMs(): Long = when {
        this == null || this <= 0 -> 0
        this < 10_000 -> this * 1000
        else -> this
    }

    private fun parseResponse(raw: String): List<LyricLineDto>? =
        parseTimedApple(raw) ?: ProviderLyrics.parse(raw)

    /**
     * The structured Apple payload, with its word timestamps intact.
     *
     * Handled before [ProviderLyrics] because that sniffs the body and a structured
     * Apple response has no `ttml` in it to find — it would be sniffed as plain
     * text and every line would arrive stamped zero. These rows carry a timestamp
     * per line *and* per word, and they are the best answer available when present.
     */
    internal fun parseTimedApple(raw: String): List<LyricLineDto>? {
        val root = runCatching { lyricsJson.parseToJsonElement(raw) }.getOrNull() ?: return null
        val content = root.findTimedContent() ?: return null
        val rows = content.mapNotNull { it as? JsonObject }
        val lines = rows.mapIndexedNotNull { index, row ->
            val start = row.long("timestamp") ?: return@mapIndexedNotNull null
            val wordRows = row["text"] as? kotlinx.serialization.json.JsonArray
                ?: return@mapIndexedNotNull null
            val texts = wordRows.mapNotNull { (it as? JsonObject)?.string("text") }
            if (texts.isEmpty()) return@mapIndexedNotNull null
            val nextLine = rows.getOrNull(index + 1)?.long("timestamp")
            val timed = wordRows.mapIndexedNotNull { wordIndex, element ->
                val word = element as? JsonObject
                    ?: return@mapIndexedNotNull null
                val text = word.string("text")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: return@mapIndexedNotNull null
                val wordStart = word.long("timestamp") ?: return@mapIndexedNotNull null
                // A word's end is the next word's start, or the next line's, or —
                // failing both — a nominal 800ms. Inventing nothing here would
                // leave the last word of every line lit forever.
                val wordEnd = (wordRows.getOrNull(wordIndex + 1)
                    as? JsonObject)?.long("timestamp")
                    ?: nextLine
                    ?: wordStart + 800
                LyricWordDto(wordStart, wordEnd.coerceAtLeast(wordStart), text)
            }
            LyricLineDto(
                timeMs = minOf(start, timed.firstOrNull()?.startMs ?: start),
                text = texts.joinToString(" ") { it.trim() },
                // Word timings only when every word has one: a partial set would
                // animate some syllables and leave the rest dead, which reads as
                // the provider being unreliable rather than as half an answer.
                words = timed.takeIf { it.size == texts.size }.orEmpty(),
                sungUntilMs = nextLine,
            )
        }
        return lines.withInstrumentalGaps()
            .takeIf { found -> found.any { it.text.isNotBlank() } }
    }

    private fun JsonElement.findTimedContent():
        kotlinx.serialization.json.JsonArray? = when (this) {
        is JsonObject -> {
            (this["content"] as? JsonArray)?.takeIf { array ->
                array.any { (it as? JsonObject)?.get("timestamp") != null }
            } ?: values.firstNotNullOfOrNull { it.findTimedContent() }
        }
        is JsonArray -> firstNotNullOfOrNull { it.findTimedContent() }
        else -> null
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)
            ?.let { it.contentOrNull?.toLongOrNull() ?: it.longOrNull }

    private fun Candidate.score(
        wantedTitle: String,
        wantedArtist: String,
        wantedDuration: Long,
    ): Int? = LyricsMatching.candidateScore(
        wantedTitle = wantedTitle,
        wantedArtist = wantedArtist,
        wantedDurationMs = wantedDuration,
        candidateTitle = title,
        candidateArtist = artist,
        candidateDurationMs = durationMs,
    )

    private suspend fun apiBody(path: String, query: Map<String, String>): String? =
        if (!hasApiKey) null
        else lyricsGetBearer(path, apiKey, query = query)

    private data class Candidate(
        val id: String,
        val title: String,
        val artist: String,
        val durationMs: Long,
    )

    private data class ParsedDocument(
        val lines: List<LyricLineDto>,
        val metadataScore: Int,
        val durationDistanceMs: Long,
    )

    private val ID_KEYS = listOf("id", "trackId", "track_id", "realId")
    private val TITLE_KEYS = listOf("name", "title", "trackName", "track_name")
    private val ARTIST_KEYS = listOf("artistName", "artist_name")
    private val DURATION_KEYS = listOf("durationInMillis", "durationMs", "duration_ms", "duration")

    private val INDEX_JS = Regex(""""/assets/index~[^\"]+\.js"""")
    private val TOKEN = Regex(""""eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"""")
}

/**
 * The key, however it was pasted.
 *
 * Both forms occur — a settings field somebody filled in by copying the whole
 * `Authorization` header value, and a bare token — and only the second works if
 * taken literally. The `Bearer ` prefix is stripped rather than the token being
 * extracted, so a key that happens to contain a space is not silently cut in half.
 */
internal fun normalizePaxSenixApiKey(value: String): String {
    val trimmed = value.trim()
    return if (trimmed.startsWith("Bearer ", ignoreCase = true)) {
        trimmed.substringAfter(' ').trim()
    } else {
        trimmed
    }
}

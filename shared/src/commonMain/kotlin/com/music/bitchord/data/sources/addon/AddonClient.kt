package com.music.bitchord.data.sources.addon

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.sources.percent
import com.music.bitchord.data.sources.module.SharedCalls
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlin.concurrent.Volatile
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Port of upstream `data/sources/addon/AddonClient.kt` — one addon server, and
 * every question this app knows how to ask it.
 *
 * Three endpoints, all GETs returning JSON, none of them executing anything on
 * this side. That is the whole point of the protocol: it replaces the module
 * index, which needs a JSON document fetched, a JavaScript file downloaded per
 * entry and an interpreter stood up, with a URL. There is no code to sandbox
 * because there is no code.
 *
 * One instance is held per configured source, so the manifest and the answers
 * shaped by it survive across tracks — see [SourceRegistry]'s instance map and
 * [SharedCalls] for why sharing matters.
 */
class AddonClient(rawBaseUrl: String) {

    /** Where this addon lives, with `/manifest.json` and trailing slashes off. */
    val baseUrl: String = normalizeBase(rawBaseUrl)

    private val json = Json {
        isLenient = true
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    private val calls = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val manifests = SharedCalls<AddonManifest>(MANIFEST_TTL, calls) { DebugLog.d(it) }
    private val searches = SharedCalls<AddonSearchResponse>(SEARCH_TTL, calls) { DebugLog.d(it) }
    private val streams = SharedCalls<AddonStream>(STREAM_TTL, calls) { DebugLog.d(it) }

    /**
     * When this addon may be spoken to again, after it said it was being asked
     * too often.
     *
     * Per-instance and not per-request: a 429 is a statement about the server, not
     * about the one call that happened to draw it, so a search landing on one
     * holds back the stream lookup queued behind it too. Without that, a fan-out
     * simply re-trips the limiter with every sibling request and the addon never
     * gets the quiet it asked for.
     */
    @Volatile
    private var quietUntil: TimeMark? = null

    // ── Manifest ──────────────────────────────────────────────────────────

    /**
     * What the addon says it is, or a failure explaining why it cannot be used.
     *
     * Strict about exactly two things: an addon with no `id` is not something that
     * can be stored or told apart from another, and one that does not declare both
     * `search` and `stream` cannot take a track from a query to audio. Failing here
     * means the sources screen can say so while the user is still looking at the
     * URL they pasted, rather than the addon being accepted and then silently
     * returning nothing on every track.
     */
    suspend fun manifest(): Result<AddonManifest> = manifests.get(
        key = baseUrl,
        describe = { "addon manifest(${redact(baseUrl)})" },
    ) {
        // Explicit type argument: `fetch` is reified, and here the expected type is
        // not inferable through `mapCatching`, so inference has nothing to go on.
        fetch<AddonManifest>(manifestUrl(baseUrl)).mapCatching { manifest ->
            if (manifest.id.isBlank()) {
                throw AddonException("That URL answered, but not with an addon manifest")
            }
            if (!manifest.isPlayable) {
                val declared = manifest.resources.joinToString(", ")
                throw AddonException("This addon declares $declared — BitChord needs search and stream")
            }
            manifest
        }.recoverCatching { failure ->
            // A manifest 404 is not "no such track", it is "no addon here" — the
            // one place the miss/fault distinction below has to be undone.
            if (failure is AddonNotFound) throw AddonException("No manifest at that URL")
            throw failure
        }
    }

    /**
     * Whether the search endpoint answers, asked without reference to a manifest.
     *
     * The manifest is a *description* of an addon and the endpoints are the addon.
     * Most of the time the description is there and is accurate, and reading it is
     * cheaper than probing — but an addon that never published one, or published it
     * under a name nothing guessed, is still a working addon, and refusing it
     * because a document was missing is refusing it for the wrong reason.
     *
     * Returns the number of tracks in the answer. Zero is a success — an addon
     * that holds nothing for one query is answering correctly — so callers must
     * read the [Result] rather than the count.
     */
    suspend fun probeSearch(): Result<Int> =
        fetch<AddonSearchResponse>(endpoint(listOf("search"), mapOf("q" to PROBE_QUERY)))
            .map { it.tracks.size }

    // ── Search ────────────────────────────────────────────────────────────

    /**
     * Tracks the addon holds for [query].
     *
     * The protocol has no limit parameter — an addon returns what it returns — so
     * trimming the list is the caller's job. Nothing else here is negotiable
     * either: the spec fixes the path, the parameter name and the shape coming back.
     */
    suspend fun search(query: String, tier: String): Result<List<AddonTrack>> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return Result.success(emptyList())
        val params = settingsFor(tier)
        return searches.get(
            // The parameters are in the key because they are in the request: the
            // same query at a different quality is a different question, and an
            // addon whose catalogue differs by tier would otherwise answer the
            // second one with the first one's rows.
            key = keyOf(trimmed, params.toString()),
            describe = { "addon search(${redact(baseUrl)}) q=\"$trimmed\" tier=$tier" },
        ) {
            fetch<AddonSearchResponse>(endpoint(listOf("search"), params + ("q" to trimmed)))
        }.map { it.tracks }
    }

    // ── Stream ────────────────────────────────────────────────────────────

    /**
     * A playable URL for one of this addon's own track ids.
     *
     * [trackId] goes in as a path *segment* rather than being interpolated into
     * the string: an addon's ids are whatever its backend uses, and one holding a
     * `/` or a `?` would otherwise rewrite the request into a different endpoint
     * entirely.
     */
    suspend fun stream(trackId: String, tier: String): Result<AddonStream> {
        val params = settingsFor(tier)
        return streams.get(
            key = keyOf(trackId, params.toString()),
            describe = { "addon stream(${redact(baseUrl)}) tier=$tier" },
        ) {
            fetch<AddonStream>(endpoint(listOf("stream", trackId), params))
        }
    }

    // ── Settings passthrough ──────────────────────────────────────────────

    /**
     * The query parameters that travel with every request.
     *
     * Two layers, and the order between them is the point. The addon's own declared
     * defaults go on first, because that is what the reference host sends when the
     * user has changed nothing, and an addon is entitled to assume it. Then
     * `quality` is set to what this app is actually asking for, overriding a
     * declared default of the same key — a request for lossless that arrived
     * carrying the manifest's `"default": "high"` is a request for lossless that
     * comes back at 320kbps.
     *
     * The value sent for `quality` is negotiated rather than asserted. This app's
     * tiers are `LOSSLESS`/`HIGH`/`LOW`, and an addon declaring a `quality` select
     * of `high|normal|low` understands none of them — sending `LOSSLESS` there is
     * not a strong ask, it is an invalid value that lands on the addon's fallback.
     * So when the manifest enumerates options the closest one is chosen from that
     * list; only when it does not is the tier name sent as-is.
     *
     * The manifest is read best-effort. It is normally already in hand and cached,
     * but an addon whose manifest is briefly unreachable while its search endpoint
     * is fine should still be searchable — one tier hint the poorer, rather than
     * failing outright on a document nothing here strictly needs.
     */
    private suspend fun settingsFor(tier: String): Map<String, String> {
        val declared = manifest().getOrNull()?.settings.orEmpty()
        val params = LinkedHashMap<String, String>()
        declared.forEach { setting ->
            val key = setting.key.takeIf { it.isNotBlank() } ?: return@forEach
            setting.defaultValue?.let { params[key] = it }
        }
        if (tier.isNotBlank()) {
            val options = declared.firstOrNull { it.key == QUALITY_KEY }
                ?.options.orEmpty()
                .map { it.stringValue }
            params[QUALITY_KEY] = matchTier(tier, options) ?: tier
        }
        return params
    }

    /**
     * The option in [options] that best answers a request for [tier], or null when
     * the addon enumerated nothing to choose from.
     *
     * Matched on what an option *says* rather than on its position, so an addon
     * listing its tiers best-first and one listing them worst-first are both read
     * correctly. Failing a word match it falls to the first option listed, which an
     * addon that bothered to order them makes its recommended tier.
     */
    private fun matchTier(tier: String, options: List<String>): String? {
        if (options.isEmpty()) return null
        options.firstOrNull { it.equals(tier, ignoreCase = true) }?.let { return it }
        val wanted = when (tier.uppercase()) {
            TIER_LOSSLESS -> LOSSLESS_WORDS
            TIER_LOW -> LOW_WORDS
            else -> HIGH_WORDS
        }
        return options.firstOrNull { option -> wanted.any { it in option.lowercase() } }
            ?: options.first()
    }

    // ── Transport ─────────────────────────────────────────────────────────

    /** `{base}/{segments…}?{params}`, with every part properly encoded. */
    private fun endpoint(segments: List<String>, params: Map<String, String>): String {
        if (baseUrl.isBlank()) throw AddonException("That is not a usable address")
        val query = params.entries
            .filter { it.value.isNotEmpty() }
            .joinToString("&") { (key, value) ->
                "${encode(key)}=${encode(value)}"
            }
        val path = segments.joinToString("/") { encode(it) }
        val base = baseUrl.trimEnd('/')
        return if (query.isEmpty()) "$base/$path" else "$base/$path?$query"
    }

    private suspend inline fun <reified T> fetch(url: String): Result<T> =
        runCatching { json.decodeFromString<T>(body(url)) }
            .onFailure { failure ->
                if (failure is CancellationException) throw failure
                // A miss is not worth a line. Everything else is: this is the only
                // place that knows why an addon didn't answer.
                if (failure !is AddonNotFound) {
                    DebugLog.w("addon call failed ${redact(url)}: ${failure.message}")
                }
            }

    /**
     * One GET, with the addon's own back-pressure honoured.
     *
     * A 429 is waited out rather than surfaced, because the alternative is a source
     * that drops out of the walk the moment it gets busy — and every caller above
     * this reads a failure as "this addon does not have the track", which is a
     * different and wrong conclusion. `Retry-After` is believed when sent;
     * otherwise the wait doubles. Both are capped, so a rate-limited addon delays a
     * track rather than stalling it.
     *
     * A 404 is deliberately its own exception. On `/stream/{id}` it is the
     * protocol's way of saying this addon does not hold that recording, which is
     * precisely the miss the caller is equipped to handle and not something to log
     * as a fault.
     */
    private suspend fun body(url: String): String = withContext(Dispatchers.Default) {
        var attempt = 0
        while (true) {
            quietUntil?.let { quiet ->
                val remaining = quiet.elapsedNow()
                if (remaining < MAX_QUIET) delay(remaining)
            }

            val wait = try {
                val response = Http.getRaw(
                    url = url,
                    headers = mapOf("Accept" to "application/json", "User-Agent" to USER_AGENT),
                    timeoutMillis = CALL_TIMEOUT_MS,
                )
                when {
                    response.status in 200..299 ->
                        return@withContext response.body?.takeIf { it.isNotBlank() }
                            ?: throw AddonException("Empty response")
                    response.status == 404 -> throw AddonNotFound()
                    // A 5xx is a server having a bad minute and will be tried again
                    // on the next track; a 4xx is this app asking for something it
                    // will never be given — a wrong URL, a token that has expired —
                    // and no amount of retrying fixes it. The sources screen renders
                    // the two differently, and painting a transient outage as a
                    // configuration error sends people to re-paste a URL that was
                    // always correct.
                    response.status >= 500 -> throw AddonUnavailable("HTTP ${response.status}")
                    response.status != 429 -> throw AddonException("HTTP ${response.status}")
                    attempt >= MAX_RETRIES -> throw AddonUnavailable("This addon is rate limiting BitChord")
                    else -> retryAfter(response.body, attempt)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: AddonNotFound) {
                throw e
            } catch (e: AddonException) {
                throw e
            } catch (e: AddonUnavailable) {
                throw e
            }
            quietUntil = TimeSource.Monotonic.markNow() + wait
            attempt++
        }
        @Suppress("UNREACHABLE_CODE")
        throw AddonException("unreachable")
    }

    /**
     * How long to wait after a 429.
     *
     * `Retry-After` is a response *header*, which the shared `Http` seam does not
     * currently surface, so the header is not available here and the exponential
     * backoff stands on its own. Recorded rather than worked around: the honest fix
     * is for [Http.getRaw] to carry response headers, which every caller of a
     * rate-limited API would then get.
     */
    private fun retryAfter(body: String?, attempt: Int): Duration {
        body?.let { text ->
            Regex("\"retryAfter\"\\s*:\\s*([0-9.]+)", RegexOption.IGNORE_CASE)
                .find(text)?.groupValues?.get(1)?.toDoubleOrNull()
                ?.let { return (it.seconds).coerceIn(BACKOFF_BASE, BACKOFF_CAP) }
        }
        return (BACKOFF_BASE * (1 shl attempt)).coerceAtMost(BACKOFF_CAP)
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    /**
     * Everything held about this addon, dropped.
     *
     * Reached when the source is edited or removed, at which point the manifest and
     * every answer shaped by it describe a server that is no longer the one
     * selected. Serving one of those afterwards would be answering a question about
     * the old address with the new one chosen.
     */
    fun clear() {
        manifests.clear()
        searches.clear()
        streams.clear()
        quietUntil = null
    }

    /**
     * Makes the next catalogue and stream lookups real requests without disturbing
     * a request already in flight.
     *
     * Used only for the listener's explicit "Upgrade quality" action. Normal
     * playback keeps those caches, but a manual retry must be able to recover
     * immediately from an addon which answered empty while one of its backends was
     * unavailable or handed out a URL that did not work.
     */
    fun clearCompletedTrackCalls() {
        searches.clearCompleted()
        streams.clearCompleted()
    }

    /** Parts joined length-prefixed, so no byte a part may contain acts as a delimiter. */
    private fun keyOf(vararg parts: String) = parts.joinToString("|") { "${it.length}:$it" }

    companion object {
        private const val TAG = "BitChord"

        /** The tiers [AddonSource] asks in. */
        const val TIER_LOSSLESS = "LOSSLESS"
        const val TIER_HIGH = "HIGH"
        const val TIER_LOW = "LOW"

        private const val QUALITY_KEY = "quality"

        private val LOSSLESS_WORDS = listOf("lossless", "flac", "hifi", "hi-res", "hires", "max", "best")
        private val HIGH_WORDS = listOf("high", "320", "normal", "standard")
        private val LOW_WORDS = listOf("low", "96", "128", "min")

        private const val MANIFEST_SUFFIX = "/manifest.json"

        /**
         * A base URL from whatever the user pasted.
         *
         * Both forms the spec names are accepted — `https://host/` and
         * `https://host/manifest.json` — because both are what people copy: an
         * addon's page lists one and the browser's address bar shows the other. A
         * token-bearing URL is left entirely intact apart from that filename, since
         * the token is *in the path* and every later call has to carry it.
         *
         * Any `.json` filename is stripped, not only `manifest.json`. A manifest
         * someone serves as `addon.json` should give the same base rather than one
         * with a document on the end of it, which would send `/search` to
         * `…/addon.json/search`.
         */
        fun normalizeBase(raw: String): String {
            val trimmed = raw.trim().trimEnd('/')
            val lastSegment = trimmed.substringAfterLast('/', "")
            return if (
                lastSegment.endsWith(".json", ignoreCase = true) && trimmed.contains("://")
            ) {
                trimmed.dropLast(lastSegment.length).trimEnd('/')
            } else {
                trimmed
            }
        }

        fun manifestUrl(base: String): String = "$base$MANIFEST_SUFFIX"

        /**
         * An addon URL with its path hidden, for logging.
         *
         * The path is what is sensitive here: this protocol puts a user's private
         * token in the path — `https://host/{token}/…` — so a log line carrying the
         * path carries the credential. The host is kept, because it is what makes a
         * line traceable to an addon at all and it is not the secret.
         */
        fun redact(url: String): String {
            val scheme = url.substringBefore("://", missingDelimiterValue = "")
            if (scheme.isEmpty()) return "***"
            val host = url.substringAfter("://").substringBefore('/').substringBefore('?')
            return "$scheme://$host/***"
        }

        /**
         * How long a manifest is trusted.
         *
         * The spec's own update story is "just update your server" — the host
         * re-fetches the manifest and users never reinstall — so this cannot be
         * cached for the session. Ten minutes picks up a new settings schema within
         * one sitting, while costing one fetch across a run of tracks.
         */
        val MANIFEST_TTL: Duration = 10.minutes

        /** Whether a catalogue holds a recording is not a fact that turns over minute to minute. */
        val SEARCH_TTL: Duration = 10.minutes

        /**
         * How long a stream URL is reused — short, because its expiry is not ours to
         * set. Five minutes sits far enough inside the reference host's one-hour
         * default to be certain, while still covering what actually repeats: the two
         * candidates one match tries in turn, and the second look arriving at the
         * same track moments later.
         */
        val STREAM_TTL: Duration = 5.minutes

        private const val MAX_RETRIES = 2
        private val BACKOFF_BASE: Duration = 500.milliseconds
        private val BACKOFF_CAP: Duration = 8.seconds
        private val MAX_QUIET: Duration = 8.seconds
        private const val CALL_TIMEOUT_MS = 20_000L
        private const val USER_AGENT = "BitChord"

        /**
         * What [probeSearch] asks for. Deliberately an ordinary word rather than a
         * nonsense string: an addon is entitled to return nothing for a query nobody
         * could match, and a probe that reliably comes back empty proves less than
         * one that usually comes back full.
         */
        private const val PROBE_QUERY = "music"
    }
}

/**
 * Something about this addon or its URL that trying again will not fix — a document
 * that is not a manifest, an addon that cannot stream, a token that is no longer
 * accepted. Surfaced as [com.music.bitchord.data.sources.SourceHealth.Rejected],
 * with a line fit to show a user.
 */
class AddonException(message: String) : Exception(message)

/**
 * The addon is momentarily not answering — down, overloaded, rate limiting. Worth
 * keeping switched on and worth asking again on the next track, which is the whole
 * distinction [com.music.bitchord.data.sources.SourceHealth] draws.
 */
class AddonUnavailable(message: String) : Exception(message)

/** The addon answered, and does not have what was asked for. A miss, not a fault. */
class AddonNotFound : Exception("Not held by this addon")

/** Percent-encoding for one path segment or query value. */
private fun encode(value: String): String =
    value.encodeToByteArray().joinToString("") { byte ->
        val c = byte.toInt().toChar()
        if ((c.isLetterOrDigit() && c.code < 128) || c in "-_.~") c.toString() else percent(byte.toInt() and 0xFF)
    }

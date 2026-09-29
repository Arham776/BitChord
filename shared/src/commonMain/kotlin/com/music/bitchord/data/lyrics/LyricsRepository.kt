package com.music.bitchord.data.lyrics

import com.music.bitchord.data.DebugLog
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Where the player gets its lyrics. Every enabled source is asked at the same
 * time; answers follow [order] rather than whichever request happens to finish
 * first. When a YouTube video id is available, exact-video sources take
 * precedence over title-matched catalogues.
 *
 * ## Matching on the recording
 *
 * Everything above matches a *name*, and a name is ambiguous in a way that
 * matters: a single and its album cut share a title, an artist and very nearly a
 * length, and routinely differ in the words. An ISRC names one recording and
 * settles it. Two sources accept one — [BiniLyrics] and [LyricsPlus] — and
 * [BiniLyrics] is also the one that hands them out, reporting the ISRC of
 * whatever its own search matched.
 *
 * So the recording is settled *before* anybody is asked for words: one small
 * search against [BiniLyrics], whose answer is a name every other source can
 * use. It costs a round trip at the head of the lookup, which is why it is
 * capped at [IDENTIFY_TIMEOUT_MS] and why its result is kept against the video
 * id — a track asked about twice pays for this once. A downloaded or local file
 * can skip it entirely: its own tags name the recording, which is what the
 * `isrc` parameter is for.
 *
 * If the playing item has a YouTube video id, sources keyed to that exact video
 * are considered before title-matched catalogs. A timed transcript for the
 * actual video beats fuzzy lyrics for a nearby version. If the exact-video
 * source has only plain text, another provider's timing is borrowed only when
 * its words substantially agree with that text.
 *
 * Only run when the user has [LyricsSource.BINI_LYRICS] enabled. It is a request
 * to a third party like any other, and a source somebody has turned off is a
 * source this app does not contact — not even for something it would only use to
 * help the sources they left on.
 *
 * ## Ordering inside the race
 *
 * A word-timed answer wins within its identity tier. A timed transcript from the
 * exact playing video takes precedence over title-matched timing; with no timed
 * exact-video answer, catalog timings are only used when they agree with any
 * exact-video lyric text.
 */
object LyricsRepository {

    /** Lyrics, and which source they turned out to come from. */
    data class Result(val source: LyricsSource, val lines: List<LyricLineDto>)

    /**
     * [sources] is the listener's pick from Settings; anything not in it is not
     * contacted at all. An empty set means no lyrics, which is the same answer as
     * switching the feature off. [order] is tried first-to-last; a source missing
     * from it (an upgrade that added one after the order was last saved) falls in
     * after everything named, in [LyricsSource]'s own order.
     *
     * [prioritizeSyllableSync] decides what happens once *something* has come
     * back: off, the first source's answer is taken as-is, word-synced or not. On,
     * an exact-video transcript is preferred over fuzzy catalog matches, and a
     * merely line-synced answer is kept as a fallback while the search checks for
     * word timings that agree with the exact text.
     */
    suspend fun lyrics(
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String? = null,
        sources: Set<LyricsSource> = LyricsSource.entries.toSet(),
        order: List<LyricsSource> = LyricsSource.entries,
        prioritizeSyllableSync: Boolean = true,
        isrc: String? = null,
        /** Called from the provider job itself, including for lazily-started ones. */
        onSourceStarted: ((LyricsSource) -> Unit)? = null,
        /**
         * Reports a completed provider attempt. A null result is a genuine miss; a
         * cancelled race loser is deliberately not reported as one.
         */
        onSourceResult: ((LyricsSource, Result?) -> Unit)? = null,
        /** Lets callers turn a cancelled race loser back into "not fetched". */
        onSourceCancelled: ((LyricsSource) -> Unit)? = null,
    ): Result? = coroutineScope {
        val configuredSequence = order.filter { it in sources } +
            LyricsSource.entries.filter { it in sources && it !in order }
        val sequence = identityAwareOrder(configuredSequence, videoId)

        // Every source but [SimpMusicLyrics] is asked for a name, and YouTube's is
        // not the name anyone catalogued. Cleaned once, here, rather than by
        // whichever source thought to do it for itself — which is how the answer
        // ended up depending on which provider happened to be enabled.
        val searchTitle = title.forLyricsSearch(artist)
        val searchArtist = artist.artistForLyricsSearch()

        // Settled before anyone is asked for words, so every source that can name
        // the recording does. What the caller knows beats what we worked out last
        // time, and both beat asking again.
        val known = isrc?.takeIf { it.isNotBlank() } ?: isrcs[videoId]
        val hit = if (known == null) {
            identify(videoId, searchTitle, searchArtist, durationMs, album, sequence)
        } else {
            null
        }
        val recording = known ?: hit?.isrc?.takeIf { it.isNotBlank() }
        if (recording != null) {
            DebugLog.d("lyrics: recording is $recording")
        }

        val racing: List<Pair<LyricsSource, Deferred<Result?>>> = sequence.map { source ->
            source to async(Dispatchers.Default) {
                onSourceStarted?.invoke(source)
                try {
                    val found = fetch(
                        source, videoId, searchTitle, searchArtist, durationMs, album,
                        recording, hit,
                    )?.let { rawLines ->
                        val lines = LyricsMatching.normalize(rawLines.withBackgroundVocals())
                        lines.takeIf { LyricsMatching.hasPlausibleDuration(it, durationMs) }
                            ?.let { Result(source, it) }
                            ?: run {
                                DebugLog.d("${source.name} returned an implausible lyric timeline; ignoring it")
                                null
                            }
                    }
                    onSourceResult?.invoke(source, found)
                    found
                } catch (cancelled: CancellationException) {
                    onSourceCancelled?.invoke(source)
                    throw cancelled
                } catch (e: Exception) {
                    DebugLog.d("${source.name} failed: ${e.message}")
                    onSourceResult?.invoke(source, null)
                    null
                }
            }
        }

        try {
            if (!prioritizeSyllableSync) {
                for ((_, job) in racing) {
                    val found = runCatching { job.await() }.getOrNull() ?: continue
                    return@coroutineScope found
                }
                return@coroutineScope null
            }

            val exactVideoSources = racing.filter { (source, _) -> source in VIDEO_ID_SOURCES }
            val catalogSources = racing.filterNot { (source, _) -> source in VIDEO_ID_SOURCES }
            var exactVideoLineSynced: Result? = null
            var exactVideoUnsynced: Result? = null
            for ((_, job) in exactVideoSources) {
                val found = runCatching { job.await() }.getOrNull() ?: continue
                if (found.lines.any { it.isWordSynced }) return@coroutineScope found
                if (found.lines.any(::hasAnyTiming)) {
                    if (exactVideoLineSynced == null) exactVideoLineSynced = found
                } else if (exactVideoUnsynced == null) {
                    exactVideoUnsynced = found
                }
            }

            // A timestamped transcript for the exact playing video is stronger
            // evidence than a word-timed fuzzy catalogue match for a nearby cut.
            exactVideoLineSynced?.let { return@coroutineScope it }

            var catalogTimedFallback: Result? = null
            var catalogUnsyncedFallback: Result? = null
            for ((_, job) in catalogSources) {
                val found = runCatching { job.await() }.getOrNull() ?: continue
                if (found.lines.any { it.isWordSynced }) {
                    val exactText = exactVideoUnsynced
                    if (exactText != null && !LyricsMatching.documentsAgree(exactText.lines, found.lines)) {
                        DebugLog.d("ignoring title-matched timed lyrics: words disagree with exact-video lyrics")
                        continue
                    }
                    return@coroutineScope found
                }
                if (found.lines.any(::hasAnyTiming)) {
                    val exactText = exactVideoUnsynced
                    if (catalogTimedFallback == null &&
                        (exactText == null || LyricsMatching.documentsAgree(exactText.lines, found.lines))
                    ) {
                        catalogTimedFallback = found
                    }
                } else if (catalogUnsyncedFallback == null) {
                    catalogUnsyncedFallback = found
                }
            }

            catalogTimedFallback ?: exactVideoUnsynced ?: catalogUnsyncedFallback
        } finally {
            // Whoever lost the race is no longer worth waiting on, and
            // `coroutineScope` will not return while they are still running.
            racing.forEach { it.second.cancel() }
        }
    }

    private suspend fun fetch(
        source: LyricsSource,
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        isrc: String?,
        /** What [identify] already found, where it ran; saves a second search. */
        hit: BiniLyrics.Hit?,
    ): List<LyricLineDto>? = when (source) {
        LyricsSource.BETTER_LYRICS -> BetterLyrics.lyrics(title, artist, durationMs, album)
        LyricsSource.BETTER_LYRICS_PORTATO -> BetterLyrics.portato(title, artist, durationMs, album)
        LyricsSource.LYRICS_PLUS -> LyricsPlus.lyrics(title, artist, durationMs, album, isrc)
        LyricsSource.BINI_LYRICS ->
            (hit?.let { BiniLyrics.lyricsFor(it) }
                ?: BiniLyrics.lyrics(title, artist, durationMs, album, isrc))
                ?.also { remember(videoId, it.isrc) }
                ?.lines
        LyricsSource.SIMP_MUSIC -> SimpMusicLyrics.lyrics(videoId, durationMs)
        LyricsSource.YOUTUBE_TRANSCRIPT -> YouTubeTranscriptLyrics.lyrics(videoId)
        LyricsSource.YOUTUBE_MUSIC -> YouTubeMusicLyrics.lyrics(videoId)
        LyricsSource.LRCLIB -> LrcLib.lyrics(title, artist, durationMs)
        LyricsSource.MUSIXMATCH -> Musixmatch.lyrics(title, artist, durationMs)
        LyricsSource.PAXSENIX -> PaxSenix.lyrics(title, artist, durationMs, album)
        LyricsSource.PAXSENIX_SPOTIFY -> PaxSenix.spotifyLyrics(title, artist, durationMs)
        LyricsSource.PAXSENIX_MUSIXMATCH -> PaxSenix.musixmatchLyrics(title, artist, durationMs)
        LyricsSource.KUGOU -> KuGou.lyrics(title, artist, durationMs, album)
        LyricsSource.UNISON -> Unison.lyrics(title, artist, durationMs, album)
        // No album and no duration: it matches on a name and does its own
        // paging, and sending a length it cannot use only narrows the results.
        LyricsSource.MEGALOBIZ -> Megalobiz.lyrics(title, artist)
        LyricsSource.GENIUS -> Genius.lyrics(title, artist)
    }

    private fun hasAnyTiming(line: LyricLineDto): Boolean =
        line.timeMs > 0L || line.words.any { it.startMs > 0L || it.endMs > 0L } ||
            line.background?.let(::hasAnyTiming) == true

    internal fun identityAwareOrder(sequence: List<LyricsSource>, videoId: String): List<LyricsSource> {
        if (!isVideoId(videoId)) return sequence
        return sequence.filter { it in VIDEO_ID_SOURCES } + sequence.filterNot { it in VIDEO_ID_SOURCES }
    }

    private val VIDEO_ID_SOURCES = setOf(
        LyricsSource.SIMP_MUSIC,
        LyricsSource.YOUTUBE_TRANSCRIPT,
        LyricsSource.YOUTUBE_MUSIC,
    )

    /**
     * Whichever source won, its lines get the same last pass: the answering
     * vocal split off the lead so it can be drawn under it. Done here rather than
     * in each parser because most of them write it as a bracket and only
     * [TtmlLyrics] knows it structurally — [withBackgroundVocals] leaves that
     * one's own split alone.
     */
    /**
     * Longest the lookup will wait to find out which recording this is.
     *
     * Short on purpose. Knowing the recording makes every match better, but not
     * knowing it only puts things back where they were a release ago, and a
     * lyrics panel sitting empty because one host is having a slow morning is a
     * worse failure than a fuzzy match.
     */
    private const val IDENTIFY_TIMEOUT_MS = 2_500L

    /**
     * The one request made before the race: which recording is this?
     *
     * Skipped entirely when the source that answers it is switched off, and given
     * up on rather than waited out — see [IDENTIFY_TIMEOUT_MS]. What it finds is
     * remembered, so a track pays for this once rather than once per lookup, and
     * the hit is handed back so [BiniLyrics] need not search twice.
     */
    private suspend fun identify(
        videoId: String,
        title: String,
        artist: String,
        durationMs: Long,
        album: String?,
        sequence: List<LyricsSource>,
    ): BiniLyrics.Hit? {
        if (LyricsSource.BINI_LYRICS !in sequence) return null
        if (!title.isUsableLyricsQuery()) return null
        val hit = withTimeoutOrNull(IDENTIFY_TIMEOUT_MS) {
            withContext(Dispatchers.Default) {
                runCatching { BiniLyrics.identify(title, artist, durationMs, album) }.getOrNull()
            }
        }
        if (hit == null) return null
        remember(videoId, hit.isrc)
        return hit
    }

    /** How many recordings to keep in hand; see [isrcs]. */
    private const val REMEMBERED = 100

    /**
     * The recording behind a video id, once something has worked it out.
     *
     * Bounded, least-recently-used, and in memory only. This is a shortcut, not a
     * store: losing it costs one fuzzy match, which is what every lookup did
     * before any of this, and keeping it on disk would mean keeping a wrong answer
     * on disk too.
     */
    private val isrcs = BoundedLru<String, String>(REMEMBERED)

    private fun remember(videoId: String, isrc: String?) {
        if (isrc.isNullOrBlank() || videoId.isEmpty()) return
        isrcs[videoId] = isrc
    }

    /** Visible for tests: what is remembered for [videoId], if anything. */
    internal fun rememberedIsrc(videoId: String): String? = isrcs[videoId]

    internal fun forget() = isrcs.clear()
}

/**
 * A small access-ordered map with a ceiling.
 *
 * A `LinkedHashMap` with access ordering is the obvious thing here, and it is
 * JVM-only — this has to build for Kotlin/Native too. Locking it is the other
 * option and is not worth it: every map this is used for is bounded at
 * [REMEMBERED] entries and written a handful of times per track, so replacing
 * the whole thing per mutation costs less than the contention a lock would, and
 * the same reasoning is already spelled out on `StreamResolver`'s own copy-on-
 * write map.
 *
 * Access-ordered rather than insertion-ordered because a track's ISRC is looked
 * up more than once — a repeat play, a pause, the read-ahead — and the entry
 * worth keeping is the one somebody is still using.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class BoundedLru<K : Any, V : Any>(private val capacity: Int) {

    private val ref = AtomicReference<Map<K, V>>(emptyMap())

    operator fun get(key: K): V? {
        val current = ref.load()
        val found = current[key] ?: return null
        // Already at the most-recent end, which is most of the time: the common
        // case must not pay for a rewrite.
        if (current.keys.lastOrNull() == key) return found
        val next = LinkedHashMap(current)
        next.remove(key)
        next[key] = found
        ref.compareAndSet(current, next)
        return found
    }

    operator fun set(key: K, value: V) {
        while (true) {
            val current = ref.load()
            val next = LinkedHashMap(current)
            next.remove(key)
            next[key] = value
            while (next.size > capacity) {
                val coldest = next.keys.firstOrNull() ?: break
                next.remove(coldest)
            }
            if (ref.compareAndSet(current, next)) return
        }
    }

    fun clear() = ref.store(emptyMap())

    val size: Int get() = ref.load().size
}

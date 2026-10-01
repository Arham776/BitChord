package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.ProbeResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlin.concurrent.Volatile
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Port of upstream `data/innertube/StreamResolver.kt` — turns a videoId into a
 * URL the engine can actually stream, and remembers enough to stop asking again.
 *
 * ## Why this file exists mostly as memory
 *
 * The Apple port previously had almost none of it, which turned out to be why a
 * session started getting *flagged* rather than merely refused. With only a
 * `preferred` client to carry between calls, every resolve walked the whole
 * client list from the top, re-asked identities that had just refused, re-minted
 * visitor ids, and did it again for the next track. Upstream is explicit that
 * this is self-inflicted:
 *
 *  > Each pass is roughly ten requests, several of them minting a fresh visitor
 *  > id, and churning identities at that rate is itself the behaviour Google
 *  > throttles — measured here as every request in a resolve going four to
 *  > twenty times slower for a stretch, which is the difference between a track
 *  > starting in three seconds and in twenty.
 *
 * So this carries the same four things upstream does: a [recent] cache of
 * already-probed URLs, [standDownUntil] per track *and* app-wide,
 * [refusalsByClient] escalating after three, and [inFlight] coalescing
 * duplicate walks rather than running them in parallel.
 *
 * ## And the signed-in retries
 *
 * The part the port was missing altogether, and the direct answer to "why is
 * this treated as a bot when upstream is not": [authenticatedStream]
 * asks [PlayerClient.WEB_REMIX] carrying the listener's real cookie once the
 * anonymous walk has been refused, and an age gate re-asks the client that
 * reported it *with* the session. Previously a bot check had nowhere to go, and
 * the answer was always "no playable stream".
 *
 * ## Threading
 *
 * Resolves run concurrently on [resolverScope] — a track playing while its
 * successor pre-caches — and so do the feedback entry points Swift calls. State
 * is held in copy-on-write maps ([CowMap]) rather than mutable ones, because
 * Kotlin/Native gives no lock and a plain `HashMap` mutated from two threads is
 * corruption rather than a lost update. Every map here is bounded and small
 * (a few dozen entries), so replacing the whole map per mutation is cheaper than
 * it sounds.
 */
object StreamResolver {

    // ---- Client list --------------------------------------------------------

    /**
     * Player clients in the order they are worth asking, cheapest and most
     * reliable first — upstream's order, taken from what the live endpoint
     * actually answers rather than from what ought to work.
     *
     * The four at the top return plain `url` fields, so a stream is one POST away
     * with no player JavaScript involved. [PlayerClient.ANDROID] below them hands
     * back ciphered formats, costing a signature solve.
     *
     * No browser client appears here, for upstream's reason: sent bare they are
     * ciphered without exception and usually refused, so they would be a slow way
     * to reach nothing. They are the *signed-in* fallback instead — see
     * [authenticatedStream] — which is the one case a cookie belongs on
     * one.
     *
     * CDN refusals stay local to the media URL. Session-wide stand-down is
     * reserved for player-client refusals, separately for guest and signed-in.
     */
    private val CLIENTS = listOf(
        PlayerClient.ANDROID_MUSIC,
        PlayerClient.TVHTML5,
        PlayerClient.ANDROID_VR,
        PlayerClient.ANDROID_VR_LEGACY,
        PlayerClient.IOS,
        PlayerClient.IOS_RECENT,
        PlayerClient.ANDROID,
    )

    /**
     * [CLIENTS], led by whichever one last worked.
     *
     * Google's decisions apply to the whole app for as long as they last, not to
     * one track, so the client that served the previous song is overwhelmingly
     * likely to serve this one — and starting there keeps the common case at a
     * single round trip.
     */
    private fun clientOrder(): List<PlayerClient> {
        val first = preferred ?: return CLIENTS
        if (isStoodDown(clientKey(first))) return CLIENTS
        return listOf(first) + CLIENTS.filterNot { it == first }
    }

    @Volatile
    private var preferred: PlayerClient? = null

    // ---- Entry points -------------------------------------------------------

    /**
     * A directly streamable URL that has been proven to serve bytes.
     *
     * @param maxKbps the ceiling from the audio-quality setting, or
     *   [Int.MAX_VALUE] for "no ceiling".
     * @throws PermanentlyUnplayableException when the answer is a verdict rather
     *   than a failure — a takedown, a region block — so the retries stacked
     *   above this one stop asking.
     */
    suspend fun resolve(videoId: String, maxKbps: Int = Int.MAX_VALUE): ResolvedStream? {
        // Before anything asks. Without a visitor id the good clients refuse
        // outright and the rest hand back URLs that only *look* like they work.
        val generation = Innertube.sessionGeneration
        runCatching { Innertube.ensureVisitorData() }
        Innertube.checkSession(generation)

        recent.snapshot()[videoId]
            ?.takeIf { it.generation == Innertube.sessionGeneration }
            ?.takeIf { it.at.elapsedNow() < URL_TTL }
            ?.takeIf { maxKbps == Int.MAX_VALUE || it.stream.kbps <= maxKbps }
            ?.let { return it.stream }

        unplayableReason(videoId)?.let { throw PermanentlyUnplayableException(it) }

        val stream = coalescedResolve(videoId, maxKbps)
        Innertube.checkSession(generation)
        // Only ever stored once it has served bytes, so this is a cache of
        // known-good answers rather than of recent attempts. A capped caller gets
        // no entry, because a download must not inherit playback's bitrate.
        if (maxKbps == Int.MAX_VALUE) remember(videoId, stream, generation)
        return stream
    }

    /**
     * One walk per track-and-ceiling at a time.
     *
     * Read-ahead resolves the queued track before it is reached, so if the queue
     * advances faster than that walk finishes, playback asks for the same track
     * again before the first walk has stored anything. Left alone that is two full
     * walks in flight for one track, each paying for the other's requests.
     *
     * This replaces a single global mutex, which serialised *every* resolve in the
     * app — the track being waited on and the pre-cached one behind it — rather
     * than coalescing only the duplicates.
     */
    private suspend fun coalescedResolve(videoId: String, maxKbps: Int): ResolvedStream {
        val key = "${Innertube.sessionGeneration}|$videoId|$maxKbps"
        recent.snapshot()[videoId]
            ?.takeIf { it.generation == Innertube.sessionGeneration }
            ?.takeIf { it.at.elapsedNow() < URL_TTL }
            ?.takeIf { maxKbps == Int.MAX_VALUE || it.stream.kbps <= maxKbps }
            ?.let { return it.stream }

        inFlight.snapshot()[key]?.let { return it.await() }

        val walk = resolverScope.async(start = CoroutineStart.LAZY) {
            resolveUncached(videoId, maxKbps)
        }
        var existing: Deferred<ResolvedStream>? = null
        inFlight.update { m ->
            val found = m[key]
            if (found != null) existing = found else m[key] = walk
        }
        existing?.let {
            // Started lazily, so losing the race costs nothing: the walk being
            // discarded has not run a line, so cancelling it fires no requests.
            walk.cancel()
            return it.await()
        }
        // Unregistered by the walk's own completion, not by the awaiter — an
        // awaiter that gives up must not take the walk others may be waiting on
        // out of the map with it.
        walk.invokeOnCompletion { inFlight.update { m -> if (m[key] === walk) m.remove(key) } }
        walk.start()
        return walk.await()
    }

    private val inFlight = CowMap<String, Deferred<ResolvedStream>>()

    private val resolverScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private suspend fun resolveUncached(videoId: String, maxKbps: Int): ResolvedStream {
        val errors = mutableListOf<String>()
        val generation = Innertube.sessionGeneration
        val canAuthenticate = if (Innertube.cookie == null) false else try {
            Innertube.ensureSessionScope()
            Innertube.checkSession(generation)
            Innertube.requestSession().cookie != null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errors += "Signed-in playback: ${e.message}"
            false
        }
        val stream = playerStream(videoId, maxKbps, errors, canAuthenticate)
            ?: if (canAuthenticate) authenticatedStream(videoId, maxKbps, errors) else null
        if (stream != null) return stream

        if (errors.isEmpty()) errors += "Playback clients are temporarily unavailable; try again shortly"
        DebugLog.w("$videoId: every player client refused. ${errors.joinToString("; ")}")
        permanentReason(errors)?.let { reason ->
            rememberUnplayable(videoId, reason)
            DebugLog.w("$videoId is not playable: $reason; not asking again for 10 minutes")
            throw PermanentlyUnplayableException(reason)
        }
        // The reasons travel with the failure rather than staying in the log. The log
        // is read by whoever is already looking; this is read by the app, and "No
        // playable stream for fJ9rUzIMcZQ" is not a sentence anybody can act on — the
        // difference between "YouTube is refusing every client" and "this track is not
        // available" is the whole of what a listener is told. The app turns it into
        // something to show; the detail is here for it to be honest about.
        throw IllegalStateException(
            "No playable stream for $videoId: ${errors.joinToString("; ")}",
        )
    }

    /**
     * A reason no amount of asking will change, read off what the walk saw.
     *
     * Deliberately only phrases that name one verdict for one track. "Video
     * unavailable" is absent, and has to stay absent: Google says it while
     * bot-checking as readily as while refusing, and treating that as permanent is
     * what would turn one flagged track into a track nobody can play for ten
     * minutes.
     */
    private fun permanentReason(errors: List<String>): String? =
        errors.firstOrNull { reason ->
            PERMANENT_REASONS.any { reason.contains(it, ignoreCase = true) }
        }

    private val PERMANENT_REASONS = listOf(
        "not available in your country",
        "who has blocked it in your country",
        "removed by the uploader",
        "account associated with this video has been terminated",
        "private video",
        "members-only",
    )

    // ---- The anonymous walk -------------------------------------------------

    /**
     * Walks [CLIENTS] until one produces a URL that actually serves audio.
     *
     * Every step is allowed to fail without taking the attempt with it: a client
     * can be refused the track, offer nothing this engine can play, hand back
     * formats none of which unlock, or mint a URL that is dead on arrival. Only
     * running out of clients is a failure.
     */
    private suspend fun playerStream(
        videoId: String,
        maxKbps: Int,
        errors: MutableList<String>,
        canAuthenticate: Boolean,
    ): ResolvedStream? {
        val generation = Innertube.sessionGeneration
        var timestamp: Int? = null
        var mintedFreshVisitor = false
        for (client in clientOrder()) {
            Innertube.checkSession(generation)
            if (isStoodDown(videoId, client)) continue

            // Only fetched when a client that needs it is reached — it costs a
            // download of YouTube's player JavaScript.
            if (client.needsSignatureTimestamp && timestamp == null) {
                timestamp = timestampProvider()
                Innertube.checkSession(generation)
                if (timestamp == null) {
                    DebugLog.d("$videoId: no signatureTimestamp; skipping ${client.clientName}")
                    errors += "${client.clientName}: no signature timestamp"
                    continue
                }
            }

            val response = try {
                Innertube.player(videoId, client, timestamp)
            } catch (e: Innertube.UnplayableException) {
                when {
                    e.isPermanent -> throw e

                    // A visitor id can be burned while the session around it is
                    // fine, and the only symptom is being called a bot. Worth one
                    // fresh id and one more try, once per resolve.
                    e.looksLikeBotCheck && !mintedFreshVisitor -> {
                        mintedFreshVisitor = true
                        DebugLog.d(
                            "$videoId: bot check from ${client.clientName}; minting a fresh visitor id",
                        )
                        runCatching { Innertube.ensureVisitorData(refresh = true) }
                        try {
                            Innertube.player(videoId, client, timestamp)
                        } catch (retry: Innertube.UnplayableException) {
                            noteRefusal(client, videoId, retry, errors)
                            continue
                        }
                    }

                    else -> {
                        noteRefusal(client, videoId, e, errors)
                        continue
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A transport failure is retried inside [Innertube] and only reaches
                // here once it has genuinely stopped being weather. It says nothing
                // about the client, so it must not stand one down — a bad minute
                // on the connection would otherwise take a good client out of
                // service for ten minutes.
                DebugLog.w("$videoId: ${client.clientName} failed: ${e.message}")
                errors += "${client.clientName}: ${e.message}"
                continue
            }

            val formats = rankForPlayback(response, maxKbps)
            if (formats.isEmpty()) {
                // What it found, not what it could not use. "no audio formats" is a
                // statement about the *filter*, and the filter is rarely the answer: the
                // iOS client as of September 2026 answers with two dozen adaptive
                // formats, the two audio-bearing ones among them included, and gives
                // not one of them a `url` or a `signatureCipher` — everything is
                // server-side ABR now. Saying "no audio formats" sends the next reader
                // to the filter when the truth is about the client.
                val offered = countFormats(response)
                val detail = when {
                    offered == 0 -> "no formats at all"
                    else -> "$offered format(s), none of them with a direct address"
                }
                DebugLog.d("$videoId: ${client.clientName} offered $detail")
                errors += "${client.clientName}: $detail"
                standDown(videoId, client)
                refused(videoId, client)
                continue
            }

            val errorsBeforeProbe = errors.size
            var picked = firstPlayable(videoId, client, formats, errors, loudnessDbOf(response))
            // A CDN can refuse a freshly issued URL while a new player read
            // issues a usable one. For guests, permit one fresh read of the
            // Android client; never replay the refused media URL. Signed-in
            // listeners take the authenticated fallback instead.
            if (picked == null && !canAuthenticate && client == PlayerClient.ANDROID &&
                errors.drop(errorsBeforeProbe).any { "media HTTP 403" in it }) {
                try {
                    val fresh = Innertube.player(videoId, client, timestamp)
                    picked = firstPlayable(videoId, client, rankForPlayback(fresh, maxKbps), errors, loudnessDbOf(fresh))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    errors += "${client.clientName}: fresh player read failed (${e.message})"
                }
            }
            if (picked != null) {
                served(client)
                preferred = client
                DebugLog.d("resolved $videoId via ${client.clientName}@${client.clientVersion} @ ${picked.kbps}kbps")
                return picked
            }
            // A track's CDN URLs are not a verdict about every other track.
            // In particular, speculative prefetch must not disable the last
            // working client after three songs happened to return dead URLs.
            // Do not cache this transient failure: Back/Next can ask for a fresh URL.
        }
        return null
    }

    /**
     * The first format on the ladder that can be unlocked into a URL, walking down
     * it rather than taking one shot at the top.
     *
     * A single pick at the top conflates two different things: a client being
     * refused the track, and the one format that happened to win on bitrate being
     * the one whose URL cannot be unlocked. A response is routinely a mix, some
     * entries with a plain `url` and some ciphered, and ranking by bitrate alone is
     * blind to which is which — so a broken solver would throw away whole clients
     * that were offering a serviceable unciphered rung one step down.
     */
    private suspend fun firstPlayable(
        videoId: String,
        client: PlayerClient,
        formats: List<AudioFormat>,
        errors: MutableList<String>,
        loudnessDb: Double? = null,
    ): ResolvedStream? {
        val generation = Innertube.sessionGeneration
        for (format in formats) {
            val url = if (format.url != null) {
                urlTransform(format.url)
            } else if (!SignatureSolver.isBroken && format.signatureCipher != null) {
                CipherUnlock.unlockCipher(videoId, format.signatureCipher)
            } else null
            Innertube.checkSession(generation)
            if (url == null) continue
            val mediaClient = PlayerClient.forStreamUrl(url)
            val mintedName = Regex("[?&]c=([^&]+)").find(url)?.groupValues?.get(1)
            val picked = ResolvedStream(
                // A signed URL belongs to the identity named by the URL, which
                // may differ from the player client (guest muxed renditions).
                // Rewriting cver changes the signed URL and can make it 403.
                url = url,
                kbps = format.kbps,
                mimeType = format.mimeType,
                headers = if (mintedName != null) mediaClient.mediaHeaders() else client.mediaHeaders(),
                loudnessDb = loudnessDb,
            )
            val result = streamProbe(picked.url, picked.headers)
            Innertube.checkSession(generation)
            if (result.classify(picked.mimeType) == ProbeVerdict.OK) return picked
            errors += "${client.clientName}@${client.clientVersion}: media HTTP ${result.status} (${picked.mimeType})"
        }
        if (errors.none { it.startsWith("${client.clientName}@${client.clientVersion}: media") }) {
            errors += "${client.clientName}@${client.clientVersion}: ${formats.size} format(s), none unlocked"
        }
        return null
    }

    /**
     * Per-track loudness from the player response, upstream's figure for the
     * normalizer (`playerConfig.audioConfig.loudnessDb`). Read off whichever
     * client won the walk — it describes the track, not the client, so the
     * first response that carries one wins. Absent more often than not (many
     * clients omit `audioConfig` entirely); null then, and the engine plays
     * at unity.
     */
    private fun loudnessDbOf(response: JsonObject): Double? =
        ((response["playerConfig"] as? JsonObject)?.get("audioConfig") as? JsonObject)
            ?.get("loudnessDb")
            ?.let { (it as? JsonPrimitive)?.content?.toDoubleOrNull() }

    /**
     * Record a refusal, and decide what it means.
     *
     * A refusal is rarely about the track alone — it usually means Google has
     * stopped answering that identity — but it is recorded per track because that
     * is the granularity it can be observed at. Repetition is what says something
     * about the client rather than the track, which is why the escalation in
     * [refused] needs no vocabulary: it waits for three.
     */
    private fun noteRefusal(
        client: PlayerClient,
        videoId: String,
        e: Innertube.UnplayableException,
        errors: MutableList<String>,
    ) {
        DebugLog.w("$videoId: ${client.clientName} refused — ${e.displayReason}")
        errors += "${client.clientName}: ${e.displayReason}"
        // A bot check is a verdict about the *session*, not about this track, so
        // it stands the client down everywhere. The rest are attributed to the
        // track until repetition says otherwise.
        if (e.looksLikeBotCheck) standDownEverywhere(client) else refused(videoId, client)
    }

    // ---- The signed-in fallback --------------------------------------------

    /** Signed-in device clients first, then the browser client. Verdicts are
     * scoped independently from anonymous attempts. Every request uses the
     * resolved account snapshot; unavailable credentials never become account 0.
     */
    private suspend fun authenticatedStream(
        videoId: String,
        maxKbps: Int,
        errors: MutableList<String>,
    ): ResolvedStream? {
        // Anonymous bot checks must not suppress the same client with a valid
        // resolved account. Device clients may return direct URLs even when
        // the web signature solver is unavailable.
        for (client in listOf(PlayerClient.ANDROID_MUSIC, PlayerClient.ANDROID, PlayerClient.TVHTML5, PlayerClient.WEB_REMIX)) {
            if (isStoodDown(videoId, client, authenticated = true)) continue
            try {
                val timestamp = if (client.needsSignatureTimestamp) timestampProvider() ?: continue else null
                val response = Innertube.player(videoId, client, timestamp, authenticated = true)
                val formats = rankForPlayback(response, maxKbps)
                if (formats.isEmpty()) {
                    errors += "Signed-in ${client.clientName}: no addressed audio formats"
                    standDown(videoId, client, authenticated = true)
                    refused(videoId, client, authenticated = true)
                    continue
                }
                val picked = firstPlayable(videoId, client, formats, errors, loudnessDbOf(response)) ?: continue
                served(client, authenticated = true)
                DebugLog.d("resolved $videoId via signed-in ${client.clientName} @ ${picked.kbps}kbps")
                return picked
            } catch (e: CancellationException) {
                throw e
            } catch (e: Innertube.UnplayableException) {
                errors += "Signed-in ${client.clientName}: ${e.displayReason}"
                if (e.looksLikeBotCheck) standDownEverywhere(client, authenticated = true)
                else standDown(videoId, client, authenticated = true)
            } catch (e: Innertube.AuthenticationException) {
                errors += "Signed-in playback: ${e.message}"
                return null
            } catch (e: Innertube.PlayerAuthenticationException) {
                errors += "Signed-in ${client.clientName}: ${e.message}"
                standDownEverywhere(client, authenticated = true)
            } catch (e: Exception) {
                errors += "Signed-in ${client.clientName}: ${e.message}"
            }
        }
        return null
    }

    // ---- Session lifecycle --------------------------------------------------

    /**
     * Forget every verdict and stand-down recorded so far.
     *
     * Signing in is the one event that can turn an age-gated track playable, and
     * signing out the one that can turn it back, so both have to clear this — a
     * listener who signs in specifically to play a track must not be told for the
     * next ten minutes that it still cannot be played. The stand-downs go with it:
     * a client refused while anonymous is owed a fresh hearing now that there is a
     * session to send, and one refused *with* a session deserves a fresh hearing
     * without it.
     */
    fun onSessionChanged() {
        inFlight.snapshot().values.forEach { it.cancel() }
        inFlight.clear()
        unplayable.clear()
        standDownUntil.clear()
        refusalsByClient.clear()
        recent.clear()
        preferred = null
        DebugLog.d("session changed; cleared resolver verdicts, stand-downs and URL cache")
    }

    /**
     * A URL that [probe] cleared has been refused while actually playing.
     *
     * Everything above assumes a URL that served bytes once will keep serving them.
     * When it doesn't, nothing here would find out: the probe runs before playback
     * and not again, so a client that goes bad mid-session stays [preferred] and
     * [recent] keeps handing back the same dead URL. Every following track then
     * fails the same way and only a restart clears it — which is the one symptom
     * users actually report.
     *
     * Only googlevideo's URLs say anything about a [PlayerClient], so anything else
     * — a module's stream URL, a downloaded file — is ignored rather than standing
     * down the client that mints most of YouTube's.
     */
    fun onPlaybackRefused(url: String, responseCode: Int) {
        if (responseCode !in REFUSAL_CODES) return
        if (!url.contains("googlevideo.com")) return
        val client = PlayerClient.forStreamUrl(url)
        // Keyed by videoId, and the fetch only knows the URL it was handed; the map
        // is a latency cache of a few dozen entries, so finding the way back costs
        // nothing worth measuring.
        recent.update { m ->
            m.entries.firstOrNull { it.value.stream.url == url }?.let { m.remove(it.key) }
        }
        // A tail-range refusal invalidates this URL, not every track minted by
        // this client. A background download must not disable foreground Next.
        DebugLog.w("${client.clientName} refused a served media URL; requesting a fresh URL")
    }

    // ---- Verdicts and stand-downs ------------------------------------------

    /**
     * A track this app cannot play, for a reason that will read the same in ten
     * seconds. Its own type because everything above the resolver has to tell it
     * apart from a failure worth retrying, and the layers in between are the
     * engine's — a load error carries whatever exception it was given and nothing
     * else, so the distinction has to travel in the type.
     */
    class PermanentlyUnplayableException(reason: String) : Exception(reason)

    private val unplayable = CowMap<String, Verdict>()

    private class Verdict(val reason: String, val at: TimeMark)

    private fun unplayableReason(videoId: String): String? {
        val entry = unplayable.snapshot()[videoId] ?: return null
        if (entry.at.elapsedNow() < UNPLAYABLE_TTL) return entry.reason
        unplayable.update { it.remove(videoId) }
        return null
    }

    private fun rememberUnplayable(videoId: String, reason: String) {
        unplayable.update { it[videoId] = Verdict(reason, TimeSource.Monotonic.markNow()) }
    }

    /** Clients refused a given track, and until when. */
    private val standDownUntil = CowMap<String, TimeMark>()

    private fun trackKey(videoId: String, client: PlayerClient, authenticated: Boolean = false) =
        "$authenticated|$videoId|${client.clientName}@${client.clientVersion}"

    private fun clientKey(client: PlayerClient, authenticated: Boolean = false) = "$authenticated|*|${client.clientName}@${client.clientVersion}"

    private fun standDown(videoId: String, client: PlayerClient, authenticated: Boolean = false) {
        standDownUntil.update { it[trackKey(videoId, client, authenticated)] = TimeSource.Monotonic.markNow() + STAND_DOWN }
    }

    private fun isStoodDown(videoId: String, client: PlayerClient, authenticated: Boolean = false): Boolean =
        isStoodDown(trackKey(videoId, client, authenticated)) || isStoodDown(clientKey(client, authenticated))

    private fun isStoodDown(key: String): Boolean {
        val until = standDownUntil.snapshot()[key] ?: return false
        // The stored mark is a deadline, not the moment the failure occurred.
        if (!until.hasPassedNow()) return true
        standDownUntil.update { it.remove(key) }
        return false
    }

    /**
     * A client refused the session rather than the track.
     *
     * Shares [standDownUntil] and its expiry with the per-track case, under a key
     * naming no video. The expiry is what makes this safe: Google's decisions here
     * last hours but not forever, so one track every [STAND_DOWN] pays for a full
     * walk and finds out whether the client is being served again, while every
     * track in between goes straight to what works.
     */
    private fun standDownEverywhere(client: PlayerClient, authenticated: Boolean = false) {
        val key = clientKey(client, authenticated)
        if (!isStoodDown(key)) {
            DebugLog.d("${client.clientName} is refusing this session; standing it down app-wide")
        }
        standDownUntil.update { it[key] = TimeSource.Monotonic.markNow() + STAND_DOWN }
        // The walk starts from whichever client last worked; one now being skipped
        // everywhere must not be that one.
        if (preferred == client) preferred = null
    }

    /**
     * Which tracks each client has been refused since it last served one.
     *
     * Google says no in whatever words it likes, and only some of them are
     * recognisable, so this does not try to read them. A client asked for one track
     * and refused has told us about that track; a client asked for three different
     * tracks and refused all three, having served nothing in between, has told us
     * about itself — whatever the wording. Videos rather than a count because one
     * track can put a client through this twice.
     */
    private val refusalsByClient = CowMap<String, Set<String>>()

    /** Low, because the cost of being wrong is bounded by [STAND_DOWN]. */
    private const val REFUSALS_BEFORE_STANDING_DOWN = 3

    private fun refused(videoId: String, client: PlayerClient, authenticated: Boolean = false) {
        val key = clientKey(client, authenticated)
        var escalate = false
        refusalsByClient.update { m ->
            val tracks = (m[key] ?: emptySet()) + videoId
            m[key] = tracks
            if (tracks.size >= REFUSALS_BEFORE_STANDING_DOWN) {
                // Cleared as it escalates, so when the stand-down expires the
                // client is owed a fresh set of refusals rather than being stood
                // down again by the first one.
                m.remove(key)
                escalate = true
            }
        }
        if (escalate) standDownEverywhere(client, authenticated)
    }

    private fun served(client: PlayerClient, authenticated: Boolean = false) {
        refusalsByClient.update { it.remove(clientKey(client, authenticated)) }
    }

    // ---- Cache --------------------------------------------------------------

    /** A resolved stream, and the headers its media fetch must repeat. */
    data class ResolvedStream(
        val url: String,
        val kbps: Int,
        val mimeType: String,
        val headers: Map<String, String>,
        /**
         * Per-track loudness from the player response (`playerConfig /
         * audioConfig / loudnessDb`), upstream's `Stream.loudnessDb`. Null
         * when the response carries none — the normalizer stays off rather
         * than inventing a figure.
         */
        val loudnessDb: Double? = null,
    )

    private class Resolved(val stream: ResolvedStream, val at: TimeMark, val generation: Long)

    /**
     * Stream URLs already resolved, by videoId — and, since only a probed one is
     * ever stored, already known good rather than merely recent.
     *
     * Google issues them with hours of validity, but the ceiling is here for a
     * different reason: a URL is tied to the session that minted it, and holding
     * one indefinitely lets a stale entry survive long enough to fail a play.
     * Twenty minutes covers a track and the seeking around it, well inside the
     * window where the URL is good.
     */
    private val recent = CowMap<String, Resolved>()

    private fun remember(videoId: String, stream: ResolvedStream, generation: Long) {
        recent.update { m ->
            if (m.size >= MAX_REMEMBERED) {
                m.entries.removeAll { it.value.at.elapsedNow() >= URL_TTL }
                if (m.size >= MAX_REMEMBERED) m.clear()
            }
            m[videoId] = Resolved(stream, TimeSource.Monotonic.markNow(), generation)
        }
    }

    // ---- Formats ------------------------------------------------------------

    internal class AudioFormat(
        val url: String?,
        val signatureCipher: String?,
        val mimeType: String,
        val kbps: Int,
    )

    /** Playable renditions within the selected data budget, ranked by codec tier.
     * Broken cipher solving makes unciphered formats preferable within that
     * budget; it never authorizes silently downloading an over-budget stream.
     */
    internal fun rankForPlayback(response: JsonObject, maxKbps: Int, signatureBroken: Boolean = SignatureSolver.isBroken): List<AudioFormat> {
        val within = audioFormats(response).filter {
            (it.kbps > 0 && it.kbps <= maxKbps) || (it.kbps == 0 && maxKbps == Int.MAX_VALUE)
        }
        val uncipheredFirst = compareByDescending<AudioFormat> { it.url != null }
        val fidelity = compareByDescending<AudioFormat> {
            if (it.mimeType.contains("opus", ignoreCase = true) && it.kbps >= 128) 2
            else if (it.kbps >= 192) 2 else if (it.kbps >= 96) 1 else 0
        }.thenByDescending { it.mimeType.contains("opus", ignoreCase = true) }
            .thenByDescending { it.kbps }.then(uncipheredFirst)
        return within.sortedWith(if (signatureBroken) uncipheredFirst.then(fidelity) else fidelity)
    }

    private fun audioFormats(response: JsonObject): List<AudioFormat> {
        val streamingData = response["streamingData"] as? JsonObject ?: return emptyList()
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return (adaptive + legacy).filterIsInstance<JsonObject>().mapNotNull { it.toAudioFormat() }
    }

    /**
     * How many formats the response held, playable or not.
     *
     * For the line that says what a client did *not* give us. Counting the audio
     * entries here would make the number agree with the filter and say nothing; the
     * useful number is what arrived.
     */
    private fun countFormats(response: JsonObject): Int {
        val streamingData = response["streamingData"] as? JsonObject ?: return 0
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return adaptive.size + legacy.size
    }

    /**
     * Audio-only, or muxed MP4 that still carries AAC — the remaining guest format
     * when adaptive audio is SABR-only.
     */
    private fun JsonObject.toAudioFormat(): AudioFormat? {
        val mime = (get("mimeType") as? JsonPrimitive)?.contentOrNull ?: return null
        val audioOnly = mime.startsWith("audio/")
        val muxedAac = mime.startsWith("video/mp4") && mime.contains("mp4a", ignoreCase = true)
        if (!audioOnly && !muxedAac) return null
        // AAC and Opus are both supported by the Apple native decoder.
        val url = (get("url") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        val cipher = (get("signatureCipher") as? JsonPrimitive)?.contentOrNull
            ?: (get("cipher") as? JsonPrimitive)?.contentOrNull
        if (url == null && cipher == null) return null
        val bps = (get("bitrate") as? JsonPrimitive)?.intOrNull ?: 0
        return AudioFormat(url, cipher, mime, (bps / 1000).coerceAtLeast(0))
    }

    // ---- Constants ----------------------------------------------------------

    private val REFUSAL_CODES = setOf(403, 404, 410)

    // Synthetic transport seams exercise the real resolver, including verdict
    // memory and coalescing, without depending on live provider responses.
    internal var streamProbe: suspend (String, Map<String, String>) -> ProbeResult = { url, headers -> Http.probe(url, headers) }
    internal var timestampProvider: suspend () -> Int? = { CipherUnlock.signatureTimestamp() }
    internal var urlTransform: suspend (String) -> String? = { CipherUnlock.transformUrl(it) }

    /**
     * Google's verdicts here last hours rather than a session, and so does the
     * money this saves: long enough that the churn cannot re-form, short enough
     * that a listener who fixes the cause does not have to restart the app.
     */
    private val STAND_DOWN: Duration = 10.minutes
    private val UNPLAYABLE_TTL: Duration = STAND_DOWN
    private val URL_TTL: Duration = 20.minutes

    /** Enough for the queue in hand; this is a latency cache, not a store. */
    private const val MAX_REMEMBERED = 32
}

/**
 * A map that is safe to read and write from several coroutines without a lock.
 *
 * Kotlin/Native offers no `synchronized` and no concurrent map in common code, and
 * a plain `HashMap` touched from two threads is corruption rather than a lost
 * update. So mutations are copy-on-write against an atomic reference: [update]
 * rebuilds the map and installs it only if nobody else got there first, retrying
 * on the collision.
 *
 * Every map this is used for is bounded and small — a few dozen entries at most —
 * so replacing one wholesale per mutation costs less than the contention a lock
 * would.
 *
 * [update]'s block may run more than once, so it must be free of side effects
 * outside the map it is handed.
 */
@OptIn(ExperimentalAtomicApi::class)
private class CowMap<K : Any, V : Any> {

    private val ref = AtomicReference<Map<K, V>>(emptyMap())

    fun snapshot(): Map<K, V> = ref.load()

    fun update(block: (MutableMap<K, V>) -> Unit) {
        while (true) {
            val current = ref.load()
            val next = LinkedHashMap(current)
            block(next)
            if (ref.compareAndSet(current, next)) return
        }
    }

    fun clear() {
        ref.store(emptyMap())
    }
}

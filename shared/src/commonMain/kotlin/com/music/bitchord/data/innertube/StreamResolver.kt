package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
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
 * this treated as a bot when upstream is not": [authenticatedWebRemixStream]
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
     * [authenticatedWebRemixStream] — which is the one case a cookie belongs on
     * one.
     *
     * This list used to be reordered locally, with [PlayerClient.ANDROID_VR]
     * deleted outright because it "mints honeypot URLs on this network". A
     * per-network observation does not belong in the client list: it is
     * [standDown]'s job, and now it is one. A client that answers with a URL which
     * fails a 2 MiB [Http.probe] is stood down on the spot, so a network that
     * dislikes ANDROID_VR no longer pays for it on every single track.
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
        runCatching { Innertube.ensureVisitorData() }

        recent.snapshot()[videoId]
            ?.takeIf { it.at.elapsedNow() < URL_TTL }
            ?.takeIf { maxKbps == Int.MAX_VALUE || it.stream.kbps <= maxKbps }
            ?.let { return it.stream }

        unplayableReason(videoId)?.let { throw PermanentlyUnplayableException(it) }

        val stream = coalescedResolve(videoId, maxKbps)
        // Only ever stored once it has served bytes, so this is a cache of
        // known-good answers rather than of recent attempts. A capped caller gets
        // no entry, because a download must not inherit playback's bitrate.
        if (maxKbps == Int.MAX_VALUE) remember(videoId, stream)
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
        val key = "$videoId|$maxKbps"
        recent.snapshot()[videoId]
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
        runCatching { Innertube.ensureSessionScope() }
        val errors = mutableListOf<String>()

        val stream = playerStream(videoId, maxKbps, errors)
            ?: authenticatedWebRemixStream(videoId, maxKbps)
        if (stream != null) return stream

        DebugLog.w("$videoId: every player client refused. ${errors.joinToString("; ")}")
        permanentReason(errors)?.let { reason ->
            rememberUnplayable(videoId, reason)
            DebugLog.w("$videoId is not playable: $reason; not asking again for 10 minutes")
            throw PermanentlyUnplayableException(reason)
        }
        throw IllegalStateException("No playable stream for $videoId")
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
    ): ResolvedStream? {
        var timestamp: Int? = null
        var mintedFreshVisitor = false
        // One signed-in retry per client per walk. Without the bound, a client
        // answering the age gate with the age gate signed in would be asked twice
        // for every walk, and there are seven of them.
        val triedSignedIn = mutableSetOf<PlayerClient>()

        for (client in clientOrder()) {
            if (isStoodDown(videoId, client)) continue

            // Only fetched when a client that needs it is reached — it costs a
            // download of YouTube's player JavaScript.
            if (client.needsSignatureTimestamp && timestamp == null) {
                timestamp = CipherUnlock.signatureTimestamp()
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

                    // A device client refused with "Sign in to confirm your age"
                    // is making a statement about the *request*, not the track: the
                    // same client asked again carrying the session is answered OK.
                    // Worth doing on these clients in particular because they
                    // return plain `url` fields, so this never touches the
                    // signature solver — which is what makes it the route that
                    // still works when the solver is broken.
                    e.isAgeGate && Innertube.cookie != null && !triedSignedIn.contains(client) -> {
                        triedSignedIn += client
                        DebugLog.d(
                            "$videoId: ${client.clientName} wants an age check; asking again signed in",
                        )
                        try {
                            Innertube.player(videoId, client, timestamp, authenticated = true)
                        } catch (retry: Innertube.UnplayableException) {
                            noteRefusal(client, videoId, retry, errors)
                            continue
                        }
                    }

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
                DebugLog.d("$videoId: ${client.clientName} offered no usable format")
                errors += "${client.clientName}: no audio formats"
                standDown(videoId, client)
                refused(videoId, client)
                continue
            }

            val picked = firstPlayable(videoId, client, formats, errors)
            if (picked == null) {
                standDown(videoId, client)
                refused(videoId, client)
                continue
            }

            when (probe(picked.url, client.mediaHeaders())) {
                ProbeVerdict.OK -> {
                    DebugLog.d(
                        "resolved $videoId via ${client.clientName}@${client.clientVersion} " +
                            "@ ${picked.kbps}kbps",
                    )
                    served(client)
                    preferred = client
                    return picked
                }
                // The client itself is being refused this track; don't spend another
                // round trip on it for a while.
                ProbeVerdict.REFUSED -> {
                    standDown(videoId, client)
                    refused(videoId, client)
                }
                // Nobody answered, so this says nothing about the client.
                ProbeVerdict.UNREACHABLE -> Unit
            }
            errors += "${client.clientName}: minted an unusable URL (${picked.mimeType})"
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
    ): ResolvedStream? {
        for (format in formats) {
            val url = format.url ?: format.signatureCipher?.let { cipher ->
                if (SignatureSolver.isBroken) {
                    null
                } else {
                    CipherUnlock.unlockCipher(videoId, cipher)
                }
            } ?: continue
            return ResolvedStream(
                url = patchClientVersion(url, client.clientVersion),
                kbps = format.kbps,
                mimeType = format.mimeType,
                headers = client.mediaHeaders(),
            )
        }
        errors += "${client.clientName}: ${formats.size} format(s), none unlocked"
        return null
    }

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

    /**
     * Tried after the anonymous walk and before giving up, and only when there is
     * a session to send: [PlayerClient.WEB_REMIX] carrying the signed-in listener's
     * own cookie.
     *
     * Upstream's reasoning, which the port had no code for at all:
     *
     *  > The anonymous walk in playerStream is refused on sight far more often than
     *  > not right now — every device client answering "sign in to confirm you're
     *  > not a bot" to a request that, honestly, isn't signed in. A real session
     *  > cookie on a browser-shaped client is the one case that isn't an anonymous
     *  > device pretending otherwise, which is why it is asked at all.
     *
     * Asked *after* the walk rather than ahead of it because of what it costs when
     * it does not work: WEB_REMIX is a web client, so every format it returns is
     * ciphered, so this is the one path that has to solve a signature on every
     * track — and a signature that cannot be solved is not a cheap no. Ahead of the
     * walk, every track would pay for the most expensive failure available before
     * anything cheaper was tried.
     *
     * Gated on [SignatureSolver] for the same reason: with the solver known broken,
     * the unciphered signed-in route inside [playerStream] is the only one that can
     * work, and this would be a round trip and a log line.
     *
     * Anything short of a working URL — no cookie, a refusal, a format that will not
     * unlock, a probe that fails — returns null rather than throwing, so a bad guess
     * here never costs more than the one round trip.
     */
    private suspend fun authenticatedWebRemixStream(
        videoId: String,
        maxKbps: Int,
    ): ResolvedStream? {
        if (Innertube.cookie == null) return null
        if (SignatureSolver.isBroken) return null
        return try {
            val timestamp = CipherUnlock.signatureTimestamp() ?: return null
            val response = Innertube.player(
                videoId = videoId,
                client = PlayerClient.WEB_REMIX,
                signatureTimestamp = timestamp,
                authenticated = true,
            )
            val formats = rankForPlayback(response, maxKbps)
            if (formats.isEmpty()) {
                DebugLog.d("$videoId: signed-in WEB_REMIX offered no usable format")
                return null
            }
            val picked = firstPlayable(
                videoId,
                PlayerClient.WEB_REMIX,
                formats,
                mutableListOf(),
            ) ?: return null
            if (probe(picked.url, PlayerClient.WEB_REMIX.mediaHeaders()) != ProbeVerdict.OK) {
                DebugLog.d("$videoId: signed-in WEB_REMIX URL did not probe clean")
                standDown(videoId, PlayerClient.WEB_REMIX)
                return null
            }
            DebugLog.d("resolved $videoId via signed-in WEB_REMIX @ ${picked.kbps}kbps")
            preferred = PlayerClient.WEB_REMIX
            picked
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            DebugLog.d("signed-in WEB_REMIX failed for $videoId: ${e.message}")
            null
        }
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
        // Independent of that lookup on purpose: dropping the preference is what
        // breaks the loop, and it must happen even if the URL already aged out.
        if (preferred == client) {
            DebugLog.w("${client.clientName} refused a URL it had already served; standing it down")
            standDownEverywhere(client)
        }
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

    private fun trackKey(videoId: String, client: PlayerClient) =
        "$videoId|${client.clientName}@${client.clientVersion}"

    private fun clientKey(client: PlayerClient) = "*|${client.clientName}@${client.clientVersion}"

    private fun standDown(videoId: String, client: PlayerClient) {
        standDownUntil.update { it[trackKey(videoId, client)] = TimeSource.Monotonic.markNow() + STAND_DOWN }
    }

    private fun isStoodDown(videoId: String, client: PlayerClient): Boolean =
        isStoodDown(trackKey(videoId, client)) || isStoodDown(clientKey(client))

    private fun isStoodDown(key: String): Boolean {
        val until = standDownUntil.snapshot()[key] ?: return false
        // A stand-down is always recorded as `now + STAND_DOWN`, so the deadline
        // has not passed while less than STAND_DOWN has elapsed since it was set.
        if (until.elapsedNow() < STAND_DOWN) return true
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
    private fun standDownEverywhere(client: PlayerClient) {
        val key = clientKey(client)
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

    private fun refused(videoId: String, client: PlayerClient) {
        val key = clientKey(client)
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
        if (escalate) standDownEverywhere(client)
    }

    private fun served(client: PlayerClient) {
        refusalsByClient.update { it.remove(clientKey(client)) }
    }

    // ---- Cache --------------------------------------------------------------

    /** A resolved stream, and the headers its media fetch must repeat. */
    data class ResolvedStream(
        val url: String,
        val kbps: Int,
        val mimeType: String,
        val headers: Map<String, String>,
    )

    private class Resolved(val stream: ResolvedStream, val at: TimeMark)

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

    private fun remember(videoId: String, stream: ResolvedStream) {
        recent.update { m ->
            if (m.size >= MAX_REMEMBERED) {
                m.entries.removeAll { it.value.at.elapsedNow() >= URL_TTL }
                if (m.size >= MAX_REMEMBERED) m.clear()
            }
            m[videoId] = Resolved(stream, TimeSource.Monotonic.markNow())
        }
    }

    // ---- Formats ------------------------------------------------------------

    private class AudioFormat(
        val url: String?,
        val signatureCipher: String?,
        val mimeType: String,
        val kbps: Int,
    )

    /**
     * Formats in the order they are worth attempting: unciphered first, then by
     * descending bitrate within the ceiling.
     *
     * Unciphered goes first outright once the solver is known broken, because a
     * ciphered format is then not merely more expensive but unplayable, and ranking
     * it first would spend the client's turn on a certainty. A rung over budget
     * still beats no audio at all, and the cheapest such rung is the least wrong,
     * so anything above the ceiling is kept ascending behind the in-budget formats.
     */
    private fun rankForPlayback(response: JsonObject, maxKbps: Int): List<AudioFormat> {
        val candidates = audioFormats(response)
        val uncipheredFirst = compareByDescending<AudioFormat> { it.url != null }
        if (SignatureSolver.isBroken) return candidates.sortedWith(uncipheredFirst)
        val (within, over) = candidates.partition { it.kbps <= maxKbps }
        return within.sortedWith(compareByDescending<AudioFormat> { it.kbps }.then(uncipheredFirst)) +
            over.sortedWith(compareBy<AudioFormat> { it.kbps }.then(uncipheredFirst))
    }

    private fun audioFormats(response: JsonObject): List<AudioFormat> {
        val streamingData = response["streamingData"] as? JsonObject ?: return emptyList()
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return (adaptive + legacy).filterIsInstance<JsonObject>().mapNotNull { it.toAudioFormat() }
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
        val url = (get("url") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        val cipher = (get("signatureCipher") as? JsonPrimitive)?.contentOrNull
            ?: (get("cipher") as? JsonPrimitive)?.contentOrNull
        if (url == null && cipher == null) return null
        val bps = (get("bitrate") as? JsonPrimitive)?.intOrNull ?: 0
        return AudioFormat(url, cipher, mime, (bps / 1000).coerceAtLeast(1))
    }

    // ---- Constants ----------------------------------------------------------

    private val REFUSAL_CODES = setOf(403, 404, 410)

    private suspend fun probe(url: String, headers: Map<String, String>): ProbeVerdict =
        Http.probe(url, headers).classify()

    /**
     * Align the URL's `cver` with the client that actually asked.
     *
     * The player response fills it in from the request, but a signature or `n`
     * transform can be solved against player JavaScript of a different vintage, and
     * googlevideo answers a version it does not expect with a 403.
     */
    private fun patchClientVersion(url: String, clientVersion: String): String =
        if ("cver=" in url) url.replace(Regex("cver=[^&]+"), "cver=$clientVersion") else url

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

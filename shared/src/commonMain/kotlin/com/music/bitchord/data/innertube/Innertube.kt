package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.ProbeResult
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.music.bitchord.data.model.LikeStatus
import com.music.bitchord.data.model.PlaylistPrivacy
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.JsonArrayBuilder
import kotlin.concurrent.Volatile
import kotlin.time.Clock
import kotlinx.io.IOException

/**
 * Port of upstream `data/innertube/Innertube.kt` — the guest-browse subset
 * the Apple app consumes, plus everything playback and the account flow
 * need: the `player` endpoint walked across device clients, the `next`
 * endpoint that powers the AutoPlay radio, and the signed-in WEB_REMIX
 * session plumbing (cookie + SAPISIDHASH).
 *
 * Two kinds of client identity, for different reasons:
 *
 *  - **WEB_REMIX** against music.youtube.com for browse/search/library. It
 *    returns the full YT Music shelf layout and honours the signed-in session.
 *
 *  - **A device client** for the `player` endpoint, chosen per call. Which
 *    ones Google answers changes without notice, so [player] takes the
 *    identity as an argument and [PlayerBridge] walks a list of them rather
 *    than betting the app on any single one. See [PlayerClient].
 *
 * Authenticated requests are signed with Google's SAPISIDHASH scheme derived
 * from the stored cookie; no long-lived token is ever minted or stored.
 */
object Innertube {

    private const val MUSIC_BASE = "https://music.youtube.com/youtubei/v1"
    private const val YT_BASE = "https://www.youtube.com/youtubei/v1"
    private const val MUSIC_ORIGIN = "https://music.youtube.com"
    private const val YOUTUBE_ORIGIN = "https://www.youtube.com"

    /** Fallback WEB_REMIX version — [ensureSessionScope] replaces this with
     *  the live one from the signed-in music.youtube.com shell. */
    private const val WEB_REMIX_VERSION = "1.20250101.01.00"
    private const val WEB_REMIX_CLIENT_ID = "67"

    private const val WEB_USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private val json = Json { ignoreUnknownKeys = true }

    /** Session cookie captured by the login WebView; null = browse as guest. */
    @Volatile
    var cookie: String? = null
        set(value) {
            if (field != value) {
                // A scope kept across a sign-in would credit the new account's
                // plays to the old one, and a visitor id minted under the old
                // session is not bound to the new one.
                scope = null
                visitorData = null
                visitorDataIsSessionBound = false
            }
            field = value
        }

    /**
     * Google's per-session visitor id. Far more load-bearing than "an id for
     * stats": a `player` request that carries no visitor id is treated as a
     * client with no session at all, and Google answers it with
     * `LOGIN_REQUIRED` / "Sign in to confirm you're not a bot", or with
     * stream URLs that serve a byte to anything and then refuse every real
     * read with 403. Fetched deliberately by [ensureVisitorData] rather than
     * hoped for.
     */
    @Volatile
    private var visitorData: String? = null

    /**
     * Whether [visitorData] came from the signed-in shell rather than being
     * minted anonymously. A session-bound id must not be replaced by a later
     * anonymous mint.
     */
    @Volatile
    private var visitorDataIsSessionBound = false

    /**
     * A visitor id for this session, minting one if there isn't one yet.
     * [refresh] discards the current id — worth doing exactly once when a
     * request comes back accusing us of being a bot.
     */
    suspend fun ensureVisitorData(refresh: Boolean = false): String? {
        if (!refresh && visitorData != null) return visitorData
        runCatching { fetchVisitorData() }
            .getOrNull()
            ?.let {
                if (refresh || !visitorDataIsSessionBound) {
                    visitorData = it
                    visitorDataIsSessionBound = false
                }
            }
        return visitorData
    }

    /**
     * The service worker bootstrap the web player loads before anything else,
     * which is where a fresh visitor id comes from without needing a page. It
     * answers with an anti-hijacking prefix and then plain nested arrays, so
     * the id is found by shape rather than by a path that would rot.
     */
    private suspend fun fetchVisitorData(): String? {
        val body = Http.getText(
            "https://www.youtube.com/sw.js_data",
            headers = mapOf("User-Agent" to WEB_USER_AGENT),
        )
        val payload = json.parseToJsonElement(body.substringAfter("\n", body.drop(5)))
        return findVisitorData(payload)
    }

    private fun findVisitorData(element: JsonElement): String? = when (element) {
        is JsonArray -> element.firstNotNullOfOrNull { findVisitorData(it) }
        is JsonPrimitive -> element.contentOrNull?.takeIf { VISITOR_DATA.matches(it) }
        else -> null
    }

    /** Protobuf-in-base64; always this shape, and nothing else in there is. */
    private val VISITOR_DATA = Regex("""Cg[A-Za-z0-9_%-]{40,}""")

    // ---- Which account is this, exactly -------------------------------------

    /**
     * Who the session cookie actually acts as. A cookie is not an account:
     * one Google login carries every account the browser has signed into, and
     * nothing in the cookie says which one is meant. Guessing `X-Goog-AuthUser:
     * 0` credits history and library to the first account in the jar.
     *
     * [dataSyncId] is only ever taken from a shell that reported itself signed
     * in — Google answers an `onBehalfOfUser` it cannot tie to the cookie with
     * 401.
     */
    private class SessionScope(
        val dataSyncId: String?,
        val pageId: String?,
        val authUser: String,
        val clientVersion: String?,
    )

    @Volatile
    private var scope: SessionScope? = null

    private val scopeLock = Mutex()

    /**
     * The brand channel the listener chose to listen as, which outranks
     * whatever the session shell says.
     *
     * A Google account can own more than one YouTube identity, and the shell
     * can only ever report the one music.youtube.com serves by default. The
     * whole reason the in-app browser exists is that the listener has just said,
     * by hand, that they want a different one — so the answer is written down
     * here and every request uses it in place of the shell's.
     */
    class ChannelSelection(
        val pageId: String?,
        val dataSyncId: String?,
        /**
         * Which account in the cookie jar the channel belongs to. Null leaves
         * the shell's own answer alone: a brand channel sits under the account
         * that owns it, so this only differs when the listener switched to a
         * channel of a *different* signed-in Google account.
         */
        val authUser: String? = null,
    )

    @Volatile
    private var channelOverride: ChannelSelection? = null

    /** Adopts a page scope read out of a page the listener was actually looking at. */
    fun adoptPageScope(pageId: String?, dataSyncId: String?, authUser: String?) {
        channelOverride = if (pageId == null && dataSyncId == null) {
            null
        } else {
            ChannelSelection(pageId, dataSyncId, authUser)
        }
    }

    /**
     * Takes the session scope from a page the listener was actually looking at,
     * rather than working it out later from a fetch of our own — port of upstream
     * `adoptSessionScope`.
     *
     * The shell fetch in [fetchSessionScope] can only ever report the channel
     * music.youtube.com serves by default, and the whole reason the in-app browser
     * exists is that the listener has just told it, by hand, that they want a
     * different one. That answer is written into the page's own `ytcfg`, so it is
     * read from there and adopted whole.
     *
     * Adopting also settles [ensureSessionScope] — a scope already in hand is not
     * refetched — so the shell cannot quietly overwrite the choice with its default
     * on the next request. A page that reported itself signed out is ignored apart
     * from its client version: its `DATASYNC_ID` belongs to no account, and sending
     * one Google cannot tie to the session is answered with 401 on every request.
     */
    fun adoptSessionScope(
        pageId: String?,
        dataSyncId: String?,
        authUser: String?,
        visitorData: String?,
        clientVersion: String?,
        loggedIn: Boolean,
    ) {
        val version = clientVersion?.takeIf { it.isNotBlank() } ?: scope?.clientVersion
        if (!loggedIn) {
            DebugLog.w("captured page was signed out; not scoping requests to it")
            scope = version?.let { SessionScope(null, null, "0", it) }
            return
        }
        scope = SessionScope(
            dataSyncId = dataSyncId?.takeIf { it.isNotBlank() },
            pageId = pageId?.takeIf { it.isNotBlank() },
            authUser = authUser?.takeIf { it.isNotBlank() } ?: "0",
            clientVersion = version,
        )
        // The page's own visitor id, bound to this session — strictly better than
        // the anonymous one [fetchVisitorData] mints.
        visitorData?.takeIf { it.isNotBlank() }?.let {
            this.visitorData = it
            visitorDataIsSessionBound = true
        }
        DebugLog.d("adopted page scope: pageId=${pageId ?: "none"} authUser=${authUser ?: "0"}")
    }

    /**
     * Value accepted by Innertube as `context.user.onBehalfOfUser` — port of upstream
     * `normalizeDataSyncId`. YouTube commonly exposes `DATASYNC_ID` as
     * `account||delegated`; the second half is the active identity, while plain
     * accounts can leave it empty.
     */
    fun normalizeDataSyncId(raw: String?): String? {
        val value = raw?.takeIf { it.isNotBlank() } ?: return null
        if (!value.contains("||")) return value
        return value.substringAfter("||").takeIf { it.isNotBlank() }
            ?: value.substringBefore("||").takeIf { it.isNotBlank() }
    }

    /**
     * The identity the session is currently acting as, or null when there is no
     * session at all.
     *
     * Which channel that is *depends on the override* — the same [pageIdFor] /
     * [dataSyncIdFor] / [authUserFor] the requests themselves use, so a caller
     * asking "who am I" cannot be told a different answer from the one the next
     * request will send. That is the whole reason this is a function and not the
     * raw scope: reading the scope directly would report the shell's default
     * identity after a listener had switched to another one.
     *
     * Null `pageId` and `dataSyncId` together mean the session has not settled on
     * an identity yet, and a caller must treat that as "unknown" rather than as
     * an identity with empty fields.
     */
    fun currentIdentity(): ChannelSelection? {
        val session = scope ?: return null
        val pageId = pageIdFor(session)
        val dataSyncId = dataSyncIdFor(session)
        if (pageId == null && dataSyncId == null) return null
        return ChannelSelection(pageId, dataSyncId, authUserFor(session))
    }

    /**
     * The brand channel to send, chosen one first.
     *
     * The shape is `override ?: shell` rather than "override, else shell" as a
     * fallback chain, and the difference matters: once a channel has been chosen
     * there is no falling back to the shell's value at all, because the shell's
     * id names the *default* identity and pairing it with another channel's
     * [ChannelSelection.pageId] describes an account/page combination that does
     * not exist. A half-overridden identity is worse than an unsigned request.
     */
    private fun pageIdFor(session: SessionScope?): String? =
        channelOverride?.pageId ?: session?.pageId

    /** The account to send as `onBehalfOfUser`. No fallback, for the reason above. */
    private fun dataSyncIdFor(session: SessionScope?): String? =
        channelOverride?.dataSyncId ?: session?.dataSyncId

    /**
     * Which account in the cookie jar, chosen channel's first.
     *
     * This one *does* fall back: [ChannelSelection.authUser] is null for a
     * channel belonging to the account that is already signed in, and there is
     * nothing contradictory about the shell's answer in that case.
     */
    private fun authUserFor(session: SessionScope?): String =
        channelOverride?.authUser ?: session?.authUser ?: "0"

    private val webRemixVersion: String
        get() = scope?.clientVersion ?: WEB_REMIX_VERSION

    /**
     * Reads the session scope, once per cookie, before anything that depends
     * on being the right account. Fails open: a shell that cannot be fetched
     * leaves [scope] null and every request behaves as it did unsigned.
     */
    suspend fun ensureSessionScope() {
        val session = cookie ?: return
        if (scope != null) return
        scopeLock.withLock {
            if (scope != null || cookie != session) return
            runCatching { fetchSessionScope(session) }
                .getOrNull()
                ?.let { fresh ->
                    // A login or profile switch can happen while the shell is in
                    // flight. Never install the old cookie's answer under the
                    // new one: that is a guaranteed 401, and worse, it can
                    // credit a play to the profile that just left.
                    if (cookie != session) {
                        DebugLog.d("discarding a session scope from an account that is no longer active")
                        return@let
                    }
                    scope = fresh
                    // The shell can only ever report the identity
                    // music.youtube.com serves by default, so it is kept and the
                    // override outranks it — a disagreement here is expected
                    // whenever the listener chose a different channel, and the
                    // choice is theirs.
                    val chosen = channelOverride
                    if (chosen != null &&
                        (chosen.pageId != fresh.pageId || chosen.dataSyncId != fresh.dataSyncId)
                    ) {
                        DebugLog.w(
                            "server shell identity differs from the selected channel; " +
                                "keeping the override (pageId=${chosen.pageId ?: "none"})",
                        )
                    }
                }
        }
    }

    /**
     * The music.youtube.com shell, for its `ytcfg`. Read by regex rather than
     * evaluating the config blob. A key that moves reads as absent.
     */
    private suspend fun fetchSessionScope(session: String): SessionScope? {
        val html = Http.getText(
            "$MUSIC_ORIGIN/",
            headers = buildMap {
                put("User-Agent", WEB_USER_AGENT)
                put("Accept-Language", "en-US,en;q=0.9")
                put("Cookie", session)
                sapisidFrom(session)?.let { put("Authorization", sapisidHash(it)) }
            },
        )
        val signedIn = CONFIG_LOGGED_IN.find(html)?.groupValues?.get(1) == "true"
        val clientVersion = CONFIG_CLIENT_VERSION.find(html)?.groupValues?.get(1)
        if (!signedIn) {
            DebugLog.w("music.youtube.com served a signed-out shell; not scoping requests")
            return clientVersion?.let { SessionScope(null, null, "0", it) }
        }
        val dataSyncId = CONFIG_DATASYNC_ID.find(html)?.groupValues?.get(1)
            ?.substringBefore("||")
            ?.takeIf { it.isNotBlank() }
        val pageId = CONFIG_PAGE_ID.find(html)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        val authUser = CONFIG_SESSION_INDEX.find(html)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        CONFIG_VISITOR_DATA.find(html)?.groupValues?.get(1)
            ?.takeIf { it.isNotBlank() }
            ?.let {
                visitorData = it
                visitorDataIsSessionBound = true
            }
        return SessionScope(dataSyncId, pageId, authUser ?: "0", clientVersion)
    }

    private val CONFIG_LOGGED_IN = Regex(""""LOGGED_IN"\s*:\s*(true|false)""")
    private val CONFIG_DATASYNC_ID = Regex(""""DATASYNC_ID"\s*:\s*"([^"]+)"""")
    private val CONFIG_PAGE_ID = Regex(""""DELEGATED_SESSION_ID"\s*:\s*"([^"]+)"""")
    private val CONFIG_SESSION_INDEX = Regex(""""SESSION_INDEX"\s*:\s*"?(\d+)""")
    private val CONFIG_VISITOR_DATA = Regex(""""VISITOR_DATA"\s*:\s*"([^"]+)"""")
    private val CONFIG_CLIENT_VERSION = Regex(""""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"""")

    // ---- Public API ---------------------------------------------------------

    /**
     * Search YouTube Music. [params] is a filter chip's serialized params
     * (`SearchFilter` in the shared model); null = the "All" tab.
     */
    /**
     * The timed transcript YouTube holds for [videoId].
     *
     * `get_transcript` expects a tiny protobuf rather than JSON, and the field is
     * field 1, length-delimited: one tag byte, the id's length, then the id. The
     * id is always 11 characters, so the length never needs a varint — which is
     * what makes this hand-rolled encoding safe rather than merely convenient.
     */
    @OptIn(ExperimentalEncodingApi::class)
    suspend fun transcript(videoId: String): JsonObject = postMusic("get_transcript") {
        val id = videoId.encodeToByteArray()
        val bytes = ByteArray(2 + id.size)
        bytes[0] = 10 // field 1, wire type 2
        bytes[1] = id.size.toByte()
        id.copyInto(bytes, destinationOffset = 2)
        put("params", Base64.Default.encode(bytes))
    }

    suspend fun search(query: String, params: String? = null): JsonObject =
        postMusic("search") {
            put("query", query)
            params?.let { put("params", it) }
        }

    /** Typeahead queries for a half-typed input — queries, not results. */
    suspend fun searchSuggestions(input: String): JsonObject =
        postMusic("music/get_search_suggestions") {
            put("input", input)
        }

    /**
     * A browse page — Home (`FEmusic_home`), Explore (`FEmusic_explore`),
     * charts (`FEmusic_charts`), new releases (`FEmusic_new_releases`) and
     * detail pages are all this one endpoint with a different id, upstream's
     * `browse` verbatim. Works as a guest.
     */
    suspend fun browse(browseId: String, params: String? = null): JsonObject =
        postMusic("browse") {
            put("browseId", browseId)
            params?.let { put("params", it) }
        }

    /**
     * The next page of a paged browse response — playlists come back roughly
     * 100 rows at a time. The token is sent in the body and as query
     * parameters; both forms are honoured.
     */
    suspend fun browseContinuation(token: String): JsonObject = postMusic(
        endpoint = "browse",
        query = mapOf("ctoken" to token, "continuation" to token, "type" to "next"),
    ) {
        put("continuation", token)
    }

    /** Signed-in profile: display name, email/handle and avatar. */
    suspend fun accountMenu(): JsonObject = postMusic("account/account_menu") {}

    /**
     * The watch queue that YouTube Music would play after [videoId] — the
     * "RDAMVM" radio mix. Used to keep AutoPlay going past the last track.
     */
    suspend fun next(videoId: String): JsonObject = postMusic("next") {
        put("videoId", videoId)
        put("playlistId", "RDAMVM$videoId")
        put("isAudioOnly", true)
    }

    /**
     * The `player` response for [videoId] as seen by [client] — the audio
     * formats and whatever it takes to unlock them.
     *
     * @param signatureTimestamp sts from base.js; required when
     *   [PlayerClient.needsSignatureTimestamp] is true.
     * @param authenticated whether to carry the session cookie. Unauthenticated
     *   by default, which is right for the device clients — they are answered
     *   *because* they look like anonymous devices. It is the deliberate
     *   exception for [PlayerClient.WEB_REMIX], a browser identity that is
     *   suspicious without a session rather than with one, and for a device
     *   client that has just answered an age gate, where the anonymous request
     *   has already been refused so there is nothing left to protect. See
     *   [postPlayer] and [StreamResolver].
     * @throws UnplayableException when the track is refused rather than
     *   missing — a region block, a takedown, or the client being turned
     *   away. Callers walk on to the next client on that distinction.
     */
    suspend fun player(
        videoId: String,
        client: PlayerClient,
        signatureTimestamp: Int? = null,
        authenticated: Boolean = false,
    ): JsonObject {
        val response = postPlayer(videoId, client, signatureTimestamp, authenticated)
        val playability = response["playabilityStatus"] as? JsonObject
        val status = (playability?.get("status") as? JsonPrimitive)?.contentOrNull
        if (status != null && status != "OK") {
            throw UnplayableException(playabilityReason(playability) ?: status)
        }
        return response
    }

    /**
     * Prefer the human-readable refusal: `reason`, then nested `messages` /
     * errorScreen `subreason` (TVHTML5 often says "Video unavailable" with
     * subreason "The page needs to be reloaded").
     */
    private fun playabilityReason(playability: JsonObject?): String? {
        if (playability == null) return null
        val reason = (playability["reason"] as? JsonPrimitive)?.contentOrNull
        val sub = playability.subreason()
        return when {
            !sub.isNullOrBlank() && !reason.isNullOrBlank() &&
                !reason.contains(sub, ignoreCase = true) -> "$reason — $sub"
            !sub.isNullOrBlank() -> sub
            else -> reason
        }
    }

    private fun JsonObject.subreason(): String? {
        (get("messages") as? JsonArray)
            ?.filterIsInstance<JsonPrimitive>()
            ?.firstNotNullOfOrNull { it.contentOrNull }
            ?.let { return it }
        val errorScreen = get("errorScreen") as? JsonObject ?: return null
        fun dig(obj: JsonObject): String? {
            (obj["subreason"] as? JsonObject)?.let { sub ->
                (sub["simpleText"] as? JsonPrimitive)?.contentOrNull?.let { return it }
                (sub["runs"] as? JsonArray)
                    ?.filterIsInstance<JsonObject>()
                    ?.mapNotNull { (it["text"] as? JsonPrimitive)?.contentOrNull }
                    ?.joinToString("")
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            obj.values.forEach { v ->
                if (v is JsonObject) dig(v)?.let { return it }
            }
            return null
        }
        return dig(errorScreen)
    }

    class UnplayableException(private val reason: String) :
        IllegalStateException("Track unavailable: $reason") {

        /**
         * Whether this is Google doubting the client rather than the track
         * being unavailable. [isAgeGate] is excluded on purpose: YouTube
         * words its age gate "Sign in to confirm your age", which contains
         * "sign in" — an age gate is a verdict about one track and one
         * identity; a bot check is a verdict about the session.
         */
        val looksLikeBotCheck: Boolean
            get() = !isAgeGate && (
                reason.contains("bot", ignoreCase = true) ||
                    reason.contains("unusual traffic", ignoreCase = true) ||
                    reason.contains("sign in", ignoreCase = true) ||
                    reason.contains("login_required", ignoreCase = true) ||
                    // TVHTML5 on flagged networks — same session refusal, no
                    // "bot"/"sign in" wording (upstream StreamResolver notes).
                    reason.contains("page needs to be reloaded", ignoreCase = true)
                )

        val isAgeGate: Boolean
            get() = reason.contains("confirm your age", ignoreCase = true) ||
                reason.contains("age-restricted", ignoreCase = true) ||
                reason.contains("age restricted", ignoreCase = true) ||
                reason.contains("inappropriate for some users", ignoreCase = true)

        /**
         * Whether asking again can only ever get the same answer — a
         * takedown, a region block, a private or paid video. Deliberately
         * short; every entry a phrase Google uses for one verdict only.
         */
        val isPermanent: Boolean
            get() = PERMANENT_REASONS.any { reason.contains(it, ignoreCase = true) }

        val displayReason: String get() = reason

        private companion object {
            private val PERMANENT_REASONS = listOf(
                "not available in your country",
                "who has blocked it in your country",
                "removed by the uploader",
                "account associated with this video has been terminated",
                "private video",
                "members-only",
            )
        }
    }

    // ---- Play registration (account history / recommendations) --------------

    class PlaybackTracking(
        val playbackUrl: String,
        val watchtimeUrl: String?,
        val atrUrl: String?,
        val atrAfterSeconds: Long,
    )

    /**
     * WEB_REMIX `player` *with* the session, purely to read `playbackTracking`.
     * Device-client [player] skips auth so it never sees this block.
     */
    suspend fun playbackTracking(videoId: String, signatureTimestamp: Int?): PlaybackTracking? {
        if (cookie == null) return null
        ensureSessionScope()
        val response = postMusic("player") {
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            putJsonObject("playbackContext") {
                putJsonObject("contentPlaybackContext") {
                    put("html5Preference", "HTML5_PREF_WANTS")
                    put("referer", "$MUSIC_ORIGIN/watch?v=$videoId")
                    signatureTimestamp?.let { put("signatureTimestamp", it) }
                }
            }
        }
        val tracking = response["playbackTracking"] as? JsonObject ?: return null
        val playbackUrl = tracking.trackingUrl("videostatsPlaybackUrl") ?: return null
        return PlaybackTracking(
            playbackUrl = playbackUrl,
            watchtimeUrl = tracking.trackingUrl("videostatsWatchtimeUrl"),
            atrUrl = tracking.trackingUrl("atrUrl"),
            atrAfterSeconds = ((tracking["atrUrl"] as? JsonObject)
                ?.get("elapsedMediaTimeSeconds") as? JsonPrimitive)
                ?.contentOrNull?.toLongOrNull() ?: 5L,
        )
    }

    private fun JsonObject.trackingUrl(key: String): String? =
        ((this[key] as? JsonObject)?.get("baseUrl") as? JsonPrimitive)?.contentOrNull

    suspend fun pingPlayback(baseUrl: String, cpn: String): Int =
        pingStats(baseUrl, cpn)

    suspend fun pingWatchtime(baseUrl: String, cpn: String, seconds: Long, final: Boolean = false): Int =
        pingStats(
            baseUrl,
            cpn,
            extra = buildMap {
                put("st", "0")
                put("et", seconds.toString())
                put("cmt", seconds.toString())
                put("state", if (final) "paused" else "playing")
                if (final) put("final", "1")
            },
        )

    suspend fun pingAtr(baseUrl: String, cpn: String): Int =
        Http.getStatus(
            url = baseUrl,
            headers = statsHeaders(),
            query = mapOf("cpn" to cpn),
        )

    private suspend fun pingStats(
        baseUrl: String,
        cpn: String,
        extra: Map<String, String> = emptyMap(),
    ): Int = Http.getStatus(
        url = baseUrl,
        headers = statsHeaders(),
        query = mapOf(
            "ver" to "2",
            "c" to "WEB_REMIX",
            "cver" to webRemixVersion,
            "cpn" to cpn,
            "cplayer" to "UNIPLAYER",
            "cbr" to "Chrome",
            "cbrver" to "141.0.0.0",
            "cos" to "Windows",
            "cosver" to "10.0",
            "hl" to "en_US",
            "cr" to "US",
        ) + extra,
    )

    private fun statsHeaders(): Map<String, String> = buildMap {
        put("X-Origin", MUSIC_ORIGIN)
        put("Origin", MUSIC_ORIGIN)
        put("Referer", "$MUSIC_ORIGIN/")
        put("User-Agent", WEB_USER_AGENT)
        visitorData?.let { put("X-Goog-Visitor-Id", it) }
        putAll(authHeaders(MUSIC_ORIGIN))
    }

    fun newCpn(): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        return CharArray(16) { alphabet.random() }.concatToString()
    }

    // ---- Writes -------------------------------------------------------------

    class NotSignedInException : IllegalStateException("Sign in to YouTube Music to do that")

    private fun requireSession() {
        if (cookie == null) throw NotSignedInException()
    }

    suspend fun rate(videoId: String, status: LikeStatus) {
        requireSession()
        val endpoint = when (status) {
            LikeStatus.LIKE -> "like/like"
            LikeStatus.DISLIKE -> "like/dislike"
            LikeStatus.INDIFFERENT -> "like/removelike"
        }
        val response = postMusic(endpoint) {
            putJsonObject("target") { put("videoId", videoId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the rating: ${message ?: error}")
        }
    }

    suspend fun ratePlaylist(playlistId: String, saved: Boolean) {
        requireSession()
        val endpoint = if (saved) "like/like" else "like/removelike"
        val response = postMusic(endpoint) {
            putJsonObject("target") { put("playlistId", playlistId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the change: ${message ?: error}")
        }
    }

    /** Follow or unfollow a YouTube channel by the id supplied on its artist page. */
    suspend fun setSubscribed(channelId: String, subscribed: Boolean) {
        requireSession()
        val endpoint = if (subscribed) "subscription/subscribe" else "subscription/unsubscribe"
        val response = postMusic(endpoint) {
            putJsonArray("channelIds") { add(channelId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the subscription change: ${message ?: error}")
        }
    }

    suspend fun sendFeedback(token: String) {
        requireSession()
        postMusic("feedback") {
            putJsonArray("feedbackTokens") { add(token) }
        }
    }

    suspend fun createPlaylist(
        title: String,
        privacy: PlaylistPrivacy,
        description: String? = null,
        videoIds: List<String> = emptyList(),
    ): String {
        requireSession()
        val response = postMusic("playlist/create") {
            put("title", title)
            put("description", description.orEmpty())
            put("privacyStatus", privacy.apiValue)
            if (videoIds.isNotEmpty()) {
                putJsonArray("videoIds") { videoIds.forEach { add(it) } }
            }
        }
        return response["playlistId"]?.jsonPrimitive?.contentOrNull
            ?: findString(response, "playlistId")
            ?: error("playlist created but no id came back")
    }

    suspend fun deletePlaylist(playlistId: String) {
        requireSession()
        postMusic("playlist/delete") { put("playlistId", playlistId.removePrefix("VL")) }
    }

    private suspend fun editPlaylist(
        playlistId: String,
        actions: JsonArrayBuilder.() -> Unit,
    ): JsonObject {
        requireSession()
        val response = postMusic("browse/edit_playlist") {
            put("playlistId", playlistId.removePrefix("VL"))
            putJsonArray("actions", actions)
        }
        val status = response["status"]?.jsonPrimitive?.contentOrNull
        if (status != null && status != "STATUS_SUCCEEDED") {
            error("YouTube Music refused the edit ($status)")
        }
        return response
    }

    suspend fun addToPlaylist(playlistId: String, videoIds: List<String>): Map<String, String> {
        val response = editPlaylist(playlistId) {
            videoIds.forEach { videoId ->
                addJsonObject {
                    put("action", "ACTION_ADD_VIDEO")
                    put("addedVideoId", videoId)
                }
            }
        }
        return (response["playlistEditResults"] as? JsonArray)
            .orEmpty()
            .mapNotNull { result ->
                val added = (result as? JsonObject)
                    ?.get("playlistEditVideoAddedResultData") as? JsonObject
                    ?: return@mapNotNull null
                val videoId = (added["videoId"] as? JsonPrimitive)?.contentOrNull
                    ?: return@mapNotNull null
                val setVideoId = (added["setVideoId"] as? JsonPrimitive)?.contentOrNull
                    ?: return@mapNotNull null
                videoId to setVideoId
            }
            .toMap()
    }

    suspend fun removeFromPlaylist(playlistId: String, entries: List<Pair<String, String>>) {
        editPlaylist(playlistId) {
            entries.forEach { (setVideoId, videoId) ->
                addJsonObject {
                    put("action", "ACTION_REMOVE_VIDEO")
                    put("setVideoId", setVideoId)
                    put("removedVideoId", videoId)
                }
            }
        }
    }

    suspend fun renamePlaylist(playlistId: String, title: String) {
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_SET_PLAYLIST_NAME")
                put("playlistName", title)
            }
        }
    }

    suspend fun setPlaylistPrivacy(playlistId: String, privacy: String) {
        val p = PlaylistPrivacy.entries.firstOrNull { it.name.equals(privacy, true) }
            ?: PlaylistPrivacy.PRIVATE
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_SET_PLAYLIST_PRIVACY")
                put("playlistPrivacyStatus", p.apiValue)
            }
        }
    }

    /** Moves [setVideoId] to sit immediately before [successorSetVideoId], or last if null. */
    suspend fun movePlaylistItem(
        playlistId: String,
        setVideoId: String,
        successorSetVideoId: String?,
    ) {
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_MOVE_VIDEO_AFTER")
                put("setVideoId", setVideoId)
                if (!successorSetVideoId.isNullOrBlank()) {
                    put("movedSetVideoIdSuccessor", successorSetVideoId)
                }
            }
        }
    }

    /** First string value under [key] anywhere in [element], depth-first. */
    private fun findString(element: JsonElement, key: String): String? = when (element) {
        is JsonObject -> (element[key] as? JsonPrimitive)?.contentOrNull
            ?: element.values.firstNotNullOfOrNull { findString(it, key) }
        is JsonArray -> element.firstNotNullOfOrNull { findString(it, key) }
        else -> null
    }

    // ---- Request plumbing ---------------------------------------------------

    /**
     * Runs [block], giving a transport failure another go before letting it
     * reach the caller.
     *
     * A connection reset on mobile data is weather, not information: the request
     * was fine and asking again generally answers. It matters more than usual
     * here, because everything goes through one client — which is the point of
     * [Http] and also what makes a socket torn down under one request surface
     * as an error on whichever request picks that connection up next, having
     * nothing to do with it. Without this, one stale socket reads as a refused
     * client, which then costs a whole extra identity on the walk, which is the
     * churn that gets the network throttled.
     *
     * Only transport failures. An HTTP error status is an *answer*, and
     * repeating the question will not change it. A timeout is not weather
     * either — it is this app's own decision that the request had long enough —
     * and because a timeout is also a transport failure, retrying one silently
     * multiplied a 6-second `player` ceiling into 18 and turned a walk of seven
     * clients into a walk of well over a minute. Cancellation is never caught:
     * a resolve whose caller has walked away must stop, not retry on behalf of
     * nobody.
     */
    private suspend fun <T> withRetry(what: String, attempts: Int = 3, block: suspend () -> T): T {
        var backoff = 500L
        repeat(attempts - 1) {
            try {
                return block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!e.isTransport()) throw e
                DebugLog.d("retrying $what: ${e.message}")
            }
            delay(backoff)
            backoff *= 2
        }
        return block()
    }

    /**
     * Whether [this] is a failure of the connection rather than of the request.
     *
     * The distinction cannot be read off the exception hierarchy across engines,
     * so it is read off what the failures have in common: the request never
     * completed, so there is nothing to be an answer *about*. A refused status
     * is an answer and must not be repeated; a body that failed to parse, or a
     * contract this app got wrong, will not parse or conform the second time
     * either and is worth surfacing.
     */
    private fun Throwable.isTransport(): Boolean {
        if (this is HttpRequestTimeoutException) return false
        var current: Throwable? = this
        val seen = HashSet<Throwable>()
        while (current != null && seen.add(current)) {
            if (current is HttpRequestTimeoutException) return false
            if (current is UnplayableException || current is NotSignedInException) return false
            if (current is IOException) return true
            val text = current.message?.lowercase().orEmpty()
            if (TRANSPORT_MARKERS.any { it in text }) return true
            current = current.cause
        }
        return false
    }

    /**
     * Wording the Darwin engine uses for a connection that failed before a
     * response, which it reports as an `NSError` rather than as an
     * `IOException` the way the JVM engine does.
     */
    private val TRANSPORT_MARKERS = listOf(
        "connection reset", "connection lost", "software caused connection abort",
        "connection refused", "network connection lost", "timed out", "broken pipe",
        "nodata", "cannot connect to host", "the network connection was lost",
        "unsatisfiable constraints", "could not connect",
    )

    private suspend fun postMusic(
        endpoint: String,
        query: Map<String, String> = emptyMap(),
        bodyExtras: JsonObjectBuilder.() -> Unit,
    ): JsonObject {
        ensureSessionScope()
        val session = scope
        val clientVersion = webRemixVersion
        val body = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "WEB_REMIX")
                    put("clientVersion", clientVersion)
                    put("hl", "en")
                    put("gl", "US")
                    visitorData?.let { put("visitorData", it) }
                }
                putJsonObject("user") {
                    put("lockedSafetyMode", false)
                    dataSyncIdFor(session)?.let { put("onBehalfOfUser", it) }
                }
                putJsonObject("request") { put("useSsl", true) }
            }
            bodyExtras()
        }
        val headers = buildMap {
            put("User-Agent", WEB_USER_AGENT)
            put("X-Origin", MUSIC_ORIGIN)
            put("Origin", MUSIC_ORIGIN)
            put("Referer", "$MUSIC_ORIGIN/")
            put("X-YouTube-Client-Name", WEB_REMIX_CLIENT_ID)
            put("X-YouTube-Client-Version", clientVersion)
            visitorData?.let { put("X-Goog-Visitor-Id", it) }
            putAll(authHeaders(MUSIC_ORIGIN))
        }
        val text = withRetry("postMusic/$endpoint") {
            Http.postJson(
                url = "$MUSIC_BASE/$endpoint",
                body = json.encodeToString(JsonObject.serializer(), body),
                headers = headers,
                query = query + ("prettyPrint" to "false"),
            )
        }
        val response = json.parseToJsonElement(text) as? JsonObject
            ?: error("innertube $endpoint: unexpected response shape")
        // Browse responses carry one; a session that never happened to see
        // one would silently never play anything.
            if (visitorData == null && !visitorDataIsSessionBound) {
                visitorData = ((response["responseContext"] as? JsonObject)
                    ?.get("visitorData") as? JsonPrimitive)?.contentOrNull
            }
        return response
    }

    /**
     * Unauthenticated by default — the device clients are answered *because*
     * they look like anonymous devices; attaching a session cookie to one of
     * those is what gets it turned away with `LOGIN_REQUIRED`.
     *
     * [authenticated] is the deliberate exception, and it is the whole reason a
     * signed-in listener is not treated as a stranger. There are two callers:
     * [PlayerClient.WEB_REMIX], a browser identity that reads as suspicious
     * *without* a session; and a device client that has just answered an age
     * gate, which the same client will answer OK for once it carries the
     * cookie. See [StreamResolver].
     */
    private suspend fun postPlayer(
        videoId: String,
        playerClient: PlayerClient,
        signatureTimestamp: Int? = null,
        authenticated: Boolean = false,
    ): JsonObject {
        val body = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", playerClient.clientName)
                    put("clientVersion", playerClient.clientVersion)
                    playerClient.osName?.let { put("osName", it) }
                    playerClient.osVersion?.let { put("osVersion", it) }
                    playerClient.deviceMake?.let { put("deviceMake", it) }
                    playerClient.deviceModel?.let { put("deviceModel", it) }
                    playerClient.androidSdkVersion?.let { put("androidSdkVersion", it.toInt()) }
                    put("hl", "en")
                    put("gl", "US")
                    visitorData?.let { put("visitorData", it) }
                }
            }
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            if (playerClient.needsSignatureTimestamp && signatureTimestamp != null) {
                putJsonObject("playbackContext") {
                    putJsonObject("contentPlaybackContext") {
                        put("signatureTimestamp", signatureTimestamp)
                    }
                }
            }
        }
        val headers = buildMap {
            put("User-Agent", playerClient.userAgent)
            put("X-YouTube-Client-Name", playerClient.clientId)
            put("X-YouTube-Client-Version", playerClient.clientVersion)
            playerClient.origin?.let { put("Origin", it) }
            playerClient.referer?.let { put("Referer", it) }
            visitorData?.let { put("X-Goog-Visitor-Id", it) }
            if (authenticated) putAll(authHeaders(playerClient.apiOrigin))
        }
        val text = withRetry("player/${playerClient.clientName}") {
            Http.postJson(
                // Browser-shaped clients are served from the Music host, app
                // clients from YouTube proper. Posting WEB_REMIX at the wrong one
                // is a refused request, not a weaker one.
                url = "${playerClient.apiBase}/player",
                body = json.encodeToString(JsonObject.serializer(), body),
                headers = headers,
                query = mapOf("prettyPrint" to "false"),
                timeoutMillis = PLAYER_TIMEOUT_MS,
            )
        }
        return json.parseToJsonElement(text) as? JsonObject
            ?: error("innertube player: unexpected response shape")
    }

    /**
     * The origin a signed-in [player] call for this client has to be signed
     * for.
     *
     * Google recomputes the SAPISIDHASH digest over the origin it sees and
     * rejects a mismatch with 401, so an app client posting to
     * `www.youtube.com` signed for the music origin is not a weaker request —
     * it is a refused one. That would have made the signed-in retries look like
     * dead ends for every client that is not browser-shaped.
     */
    private val PlayerClient.apiOrigin: String
        get() = origin ?: if (usesMusicHost) MUSIC_ORIGIN else YOUTUBE_ORIGIN

    /** See [Http.postJson]'s timeout — upstream's per-player-call ceiling. */
    private const val PLAYER_TIMEOUT_MS = 6_000L

    /**
     * The session headers every signed-in WEB_REMIX request carries: the
     * cookie itself, which account in the jar, and Google's SAPISIDHASH
     * signature over the origin this request is going to. Google recomputes
     * the digest over the origin it sees and rejects a mismatch with 401.
     */
    internal fun authHeaders(origin: String = MUSIC_ORIGIN): Map<String, String> = buildMap {
        val session = cookie ?: return@buildMap
        put("Cookie", session)
        put("X-Goog-AuthUser", authUserFor(scope))
        pageIdFor(scope)?.let { put("X-Goog-PageId", it) }
        sapisidFrom(session)?.let { put("Authorization", sapisidHash(it, origin)) }
    }

    /**
     * Whether a cookie header carries a secret Innertube requests can be
     * signed with. Matched on the cookie *name* — a substring test accepts
     * `__Secure-3PAPISID` as `SAPISID` and then sends the cookie unsigned.
     */
    fun hasApiSid(cookieHeader: String): Boolean =
        cookieHeader.split(';').any { entry ->
            val name = entry.substringBefore('=').trim()
            val value = entry.substringAfter('=', "").trim()
            name in SAPISID_NAMES && value.isNotEmpty()
        }

    /**
     * The API-signing secret out of a cookie header. Three names for one
     * value, and all three have to be looked for: on a cookie-partitioned
     * login Google sets only the `__Secure-` forms. Any of them signs a
     * request; the digest does not care which it came from.
     */
    fun sapisidFrom(cookieHeader: String): String? {
        val jar = cookieHeader.split(';')
            .mapNotNull { entry ->
                val name = entry.substringBefore('=').trim()
                val value = entry.substringAfter('=', "").trim()
                if (name.isEmpty() || value.isEmpty()) null else name to value
            }
            .toMap()
        return SAPISID_NAMES.firstNotNullOfOrNull { jar[it] }
    }

    private val SAPISID_NAMES =
        listOf("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID")

    /** `SAPISIDHASH <ts>_<sha1("<ts> <sapisid> <origin>")>` — Google's scheme. */
    fun sapisidHash(sapisid: String, origin: String = MUSIC_ORIGIN): String {
        val timestamp = Clock.System.now().toEpochMilliseconds() / 1000
        val digest = Sha1.hex("$timestamp $sapisid $origin".encodeToByteArray())
        return "SAPISIDHASH ${timestamp}_$digest"
    }
}

/**
 * The verdict of a ranged GET on a freshly minted stream URL.
 *
 * [expected] is the mime type of the format the URL was minted for, and the content
 * type is judged against *it* rather than against "must be audio". That distinction
 * is the whole reason this is a parameter. A format with no adaptive audio left —
 * which is what a guest session is handed for most of the catalogue — is a muxed
 * `video/mp4` carrying AAC, [StreamResolver] takes it deliberately, and the engine
 * demuxes the audio track out of it: `native-core`'s track search looks for a track
 * that has audio and names muxed itag 18 in the comment above it. A test that insisted
 * the answer begin `audio/` threw away the only rung the ladder had, and a track that
 * resolved on a guest session resolved on nothing.
 */
internal fun ProbeResult.classify(expected: String? = null): ProbeVerdict = when {
    status in REFUSAL_STATUSES -> ProbeVerdict.REFUSED
    status !in 200..299 && status != 416 -> ProbeVerdict.UNREACHABLE
    // 416 is the end of the file and has no body to judge: a seek past the
    // container's length, which the reader treats as a clean finish.
    status == 416 -> ProbeVerdict.UNREACHABLE
    !contentType.isMediaFamilyOf(expected) -> ProbeVerdict.REFUSED
    !bodyArrived -> ProbeVerdict.UNREACHABLE
    else -> ProbeVerdict.OK
}

/** Answers that mean *this client is being refused*, rather than a bad minute. */
private val REFUSAL_STATUSES = setOf(403, 404, 410)

/**
 * Whether a content type is the kind of media [expected] asked for.
 *
 * A family rather than an equality, and that is deliberate in both directions. A
 * range for a muxed `video/mp4` is answered `video/mp4` by one server and
 * `audio/mp4` by another for the same bytes, while a `text/html` body — the shape a
 * bot check or a consent page takes — matches no family at all, and that is the case
 * this test earns its keep on.
 *
 * `application/octet-stream` matches anything, because a server declining to name a
 * type is not the same as one naming a wrong type.
 *
 * A null [expected] means nothing was asked for, and then only the outright wrong
 * answers are refused: the check is here to catch an error page, not to insist on a
 * spelling.
 */
private fun String?.isMediaFamilyOf(expected: String?): Boolean {
    val answer = this?.substringBefore(';')?.trim()?.lowercase().orEmpty()
    // A server declining to name a type is not naming a wrong one.
    if (answer == "application/octet-stream") return true
    // Only the two families the engine can take audio out of. With no format to
    // compare against this is the whole test, and it is why an error page is refused
    // rather than waved through: `text/html` has a slash in it too.
    val family = answer.substringBefore('/')
    if (family != "audio" && family != "video") return false
    val wanted = expected?.substringBefore(';')?.trim()?.lowercase()?.substringBefore('/')
        ?.takeIf { it == "audio" || it == "video" }
    return wanted == null || wanted == family
}

internal enum class ProbeVerdict {
    /** Served media bytes; safe to play. */
    OK,

    /** Answered, but refused this request — the client is the problem. */
    REFUSED,

    /** Never got an answer worth interpreting; blame nothing in particular. */
    UNREACHABLE,
}

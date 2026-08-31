package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.ProbeResult
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
                ?.let { scope = it }
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
            println("[Innertube] music.youtube.com served a signed-out shell; not scoping requests")
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
     * @throws UnplayableException when the track is refused rather than
     *   missing — a region block, a takedown, or the client being turned
     *   away. Callers walk on to the next client on that distinction.
     */
    suspend fun player(
        videoId: String,
        client: PlayerClient,
        signatureTimestamp: Int? = null,
    ): JsonObject {
        val response = postPlayer(videoId, client, signatureTimestamp)
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

    /** First string value under [key] anywhere in [element], depth-first. */
    private fun findString(element: JsonElement, key: String): String? = when (element) {
        is JsonObject -> (element[key] as? JsonPrimitive)?.contentOrNull
            ?: element.values.firstNotNullOfOrNull { findString(it, key) }
        is JsonArray -> element.firstNotNullOfOrNull { findString(it, key) }
        else -> null
    }

    // ---- Request plumbing ---------------------------------------------------

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
                    session?.dataSyncId?.let { put("onBehalfOfUser", it) }
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
        val text = Http.postJson(
            url = "$MUSIC_BASE/$endpoint",
            body = json.encodeToString(JsonObject.serializer(), body),
            headers = headers,
            query = query + ("prettyPrint" to "false"),
        )
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
     * they look like anonymous devices; attaching a session cookie is what
     * gets one turned away with `LOGIN_REQUIRED`. The cookie joins a request
     * only when present (signed-in browse/account calls).
     */
    private suspend fun postPlayer(
        videoId: String,
        playerClient: PlayerClient,
        signatureTimestamp: Int? = null,
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
        }
        val text = Http.postJson(
            url = "$YT_BASE/player",
            body = json.encodeToString(JsonObject.serializer(), body),
            headers = headers,
            query = mapOf("prettyPrint" to "false"),
            timeoutMillis = PLAYER_TIMEOUT_MS,
        )
        return json.parseToJsonElement(text) as? JsonObject
            ?: error("innertube player: unexpected response shape")
    }

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
        put("X-Goog-AuthUser", scope?.authUser ?: "0")
        scope?.pageId?.let { put("X-Goog-PageId", it) }
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

/** The verdict of a ranged GET on a freshly minted stream URL. */
internal fun ProbeResult.classify(): ProbeVerdict = when {
    status in setOf(403, 404, 410) -> ProbeVerdict.REFUSED
    status !in 200..299 && status != 416 -> ProbeVerdict.UNREACHABLE
    !isMediaContentType(contentType) -> ProbeVerdict.REFUSED
    !bodyArrived -> ProbeVerdict.UNREACHABLE
    else -> ProbeVerdict.OK
}

private fun isMediaContentType(ct: String?): Boolean {
    if (ct == null) return false
    return ct.startsWith("audio/") ||
        ct.startsWith("video/mp4") ||
        ct.startsWith("video/3gpp")
}

internal enum class ProbeVerdict {
    /** Served media bytes; safe to play. */
    OK,

    /** Answered, but refused this request — the client is the problem. */
    REFUSED,

    /** Never got an answer worth interpreting; blame nothing in particular. */
    UNREACHABLE,
}

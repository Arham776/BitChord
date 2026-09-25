package com.music.bitchord.data.sources

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.settings.PlatformSettings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.concurrent.Volatile
import kotlin.random.Random

/**
 * Port of upstream `data/sources/SourceRegistry.kt` — the user's sources, always
 * tried in the fixed order [SourceKind] declares: their own addons first, then
 * JioSaavn, then YouTube Music.
 *
 * [SourceKind.YOUTUBE] is seeded on first run and cannot be deleted, only
 * disabled — it needs no configuration, so a "remove" would delete something the
 * user could not then re-create by typing anything in. Addons are entirely
 * optional: with none configured, YouTube is the only active source on a fresh
 * install. JioSaavn is present but off until the user accepts its
 * catalogue-matching risk.
 *
 * ## Where the list is stored
 *
 * Upstream keeps it in `EncryptedSharedPreferences`, and that is not incidental:
 * an addon's `baseUrl` on this protocol can carry the user's token in its path,
 * which makes it a credential rather than a preference. So the *list* lives in
 * ordinary settings and each `baseUrl` is split out into [PlatformSettings]'s
 * secret tier, which is the Keychain on Apple. The list itself names which
 * account holds each secret rather than containing the value.
 */
object SourceRegistry {

    private const val TAG = "BitChord"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Every configured source, enabled or not. */
    private val _configs = MutableStateFlow<List<SourceConfig>>(emptyList())
    val configs: StateFlow<List<SourceConfig>> = _configs.asStateFlow()

    /**
     * Built instances, keyed by config id, rebuilt whenever [_configs] changes.
     *
     * Held rather than constructed per call so that a source with any warmed
     * state — an addon whose manifest has already been fetched — keeps it across
     * tracks instead of re-probing on every resolve.
     */
    @Volatile
    private var instances: Map<String, MusicSource> = emptyMap()

    @Volatile
    private var initialised = false

    fun init() {
        if (initialised) return
        initialised = true
        val stored = readStored()
        val jioOptInDone = PlatformSettings.getBoolean(KEY_JIOSAAVN_OPT_IN_V1, false)
        val after = sourcesForInit(
            stored,
            forceJioSaavnOff = !jioOptInDone,
            legacyModuleIndexUrl = AppSettings.moduleIndexUrl.value,
        )
        // Publish and record the migration marker together. A process that died
        // after recording the marker but before the disabled source would
        // otherwise believe the forced opt-out had happened and silently restore
        // the old on state.
        publish(after, persist = false)
        if (after != stored || !jioOptInDone) {
            writeStored(after)
            PlatformSettings.putBoolean(KEY_JIOSAAVN_OPT_IN_V1, true)
        }
    }

    /**
     * Built-in seeding and the one-time source migrations, kept pure for tests.
     *
     * [forceJioSaavnOff] is true exactly once for every install that first runs
     * this version, including upgrades whose stored config currently says on.
     * Once the marker is written, a user who deliberately enables JioSaavn is
     * left enabled on subsequent launches.
     */
    internal fun sourcesForInit(
        stored: List<SourceConfig>,
        forceJioSaavnOff: Boolean,
        legacyModuleIndexUrl: String = "",
    ): List<SourceConfig> {
        // Seeded rather than persisted-on-first-write, so a build adding a new
        // built-in kind picks it up for existing installs too. SourceConfig's
        // default is the policy: JioSaavn off, YouTube on.
        val seeded = stored + BUILT_IN_KINDS
            .filter { kind -> stored.none { it.kind == kind } }
            .map { SourceConfig(kind = it) }

        // A module index configured before sources became a list. The old
        // settings screen kept it in one key, so an install that had one working
        // would otherwise open the new screen to find it silently gone — which
        // reads as the app losing a setting rather than as a migration.
        //
        // One shot: once a `CUSTOM_MODULE` config exists the key is no longer
        // consulted, so a source added afterwards is never joined by a stale
        // duplicate of whatever used to be in the key.
        val withLegacy = if (
            legacyModuleIndexUrl.isNotBlank() && seeded.none { it.kind == SourceKind.CUSTOM_MODULE }
        ) {
            seeded + SourceConfig(
                id = "migrated-module-index",
                kind = SourceKind.CUSTOM_MODULE,
                label = "",
                baseUrl = legacyModuleIndexUrl.trim().trimEnd('/'),
            )
        } else {
            seeded
        }

        // The retired built-in module is removed; a custom module the user entered
        // is preserved, because the two are different kinds for exactly this
        // reason.
        return withLegacy
            .filterNot { it.kind == SourceKind.MODULE }
            .map { config ->
                when {
                    config.kind == SourceKind.YOUTUBE && !config.enabled -> config.copy(enabled = true)
                    config.kind == SourceKind.JIOSAAVN && forceJioSaavnOff -> config.copy(enabled = false)
                    else -> config
                }
            }
    }

    /**
     * Decodes a stored source list one entry at a time rather than as a single
     * list, so one entry naming a kind this build no longer has — left over from
     * before a kind was retired — does not take every other entry down with it. A
     * strict `List<SourceConfig>` decode fails whole: one bad enum value and the
     * user's real, working config is silently gone along with it.
     */
    private fun readStored(): List<SourceConfig> {
        val raw = PlatformSettings.getString(KEY_SOURCES, "")
        if (raw.isBlank()) return emptyList()
        val elements = runCatching { json.parseToJsonElement(raw).jsonArray }
            .getOrElse { return emptyList() }
        return elements.mapNotNull { element ->
            runCatching { json.decodeFromJsonElement(SourceConfig.serializer(), element) }
                .onFailure { DebugLog.w("dropping unreadable stored source: ${it.message}") }
                .getOrNull()
        }
    }

    private fun writeStored(configs: List<SourceConfig>) {
        PlatformSettings.putString(
            KEY_SOURCES,
            json.encodeToString(ListSerializer(SourceConfig.serializer()), configs),
        )
    }

    /**
     * The enabled sources, in the order [SourceKind.rank] declares, however they
     * are stored.
     *
     * The user's standing choice and nothing else. Both playback and downloads
     * start here, so disabling JioSaavn or an addon excludes it from both. A
     * stream is budgeted further by [activeForPlayback]; downloads deliberately
     * apply no connection-quality ceiling — see `SourceResolver.forDownload`.
     *
     * A stable sort on `rank`, so two sources of the same kind keep the stored
     * list order — which is the order the user dragged them into.
     */
    fun active(): List<MusicSource> {
        init()
        return enabledConfigs(_configs.value)
            .sortedBy { it.kind.rank }
            .mapNotNull { instances[it.id] }
    }

    /** The common eligibility gate used by the playback and download source walks. */
    internal fun enabledConfigs(configs: List<SourceConfig>): List<SourceConfig> =
        configs.filter { it.enabled && it.isComplete }

    /**
     * [active], minus the sources the ceiling on the connection in hand does not
     * pay for — see `AudioQuality.permits`.
     *
     * Every path that starts or plans a *stream* asks this rather than [active],
     * so the Wi-Fi and mobile-data rungs stay two independent answers to "what
     * does this minute cost" and switching networks switches between them.
     * Downloads deliberately keep asking [active]: what a saved file is worth is
     * the download-quality setting's question, and when it may be fetched is the
     * Wi-Fi-only setting's.
     */
    fun activeForPlayback(): List<MusicSource> {
        init()
        val ceiling = AppSettings.effectiveAudioQualityFlow.value
        return active().filter { ceiling.permits(it.kind) }
    }

    fun instance(configId: String): MusicSource? {
        init()
        return instances[configId]
    }

    fun config(configId: String): SourceConfig? {
        init()
        return _configs.value.firstOrNull { it.id == configId }
    }

    // ── Editing ─────────────────────────────────────────────────────────

    fun add(config: SourceConfig) = publish(_configs.value + config.tidied())

    fun update(config: SourceConfig) {
        val tidied = config.tidied()
        publish(_configs.value.map { if (it.id == tidied.id) tidied else it })
    }

    /**
     * The config as it should be stored, rather than as it was typed.
     *
     * Only addons have anything to tidy, and only their URL: the two forms people
     * paste — the addon's root and its `manifest.json` — address the same server,
     * and storing them as typed makes two configs that behave identically look
     * different on screen and compare unequal, which would rebuild a warm source
     * over a cosmetic edit. Normalising here rather than in the editor keeps it
     * true for every caller and not just the one with a text field.
     */
    private fun SourceConfig.tidied(): SourceConfig =
        if (kind == SourceKind.ADDON) copy(baseUrl = normalizeAddonBase(baseUrl)) else this

    fun remove(configId: String) {
        val target = config(configId) ?: return
        // A built-in cannot be removed, only switched off. A "remove" on a source
        // that needs no configuration would delete something the user could not
        // then re-create by typing anything in.
        if (target.kind in BUILT_IN_KINDS) return
        // The secret outlives the config that named it, so drop it with them.
        PlatformSettings.putSecret(secretAccount(target.id), null)
        publish(_configs.value.filterNot { it.id == configId })
    }

    /**
     * Turns one source on or off.
     *
     * YouTube is not switchable and silently ignores a request to disable it. It
     * is the only source that can supply a home feed, radio or related tracks,
     * and nothing else holds the full catalogue — switching it off does not even
     * stop it being played, because a YouTube-queued track whose substitutes all
     * miss still falls back to it. A switch that cannot honour its own off
     * position is worse than no switch, so it is not offered one.
     */
    fun setEnabled(configId: String, enabled: Boolean) {
        if (!enabled && config(configId)?.kind == SourceKind.YOUTUBE) return
        publish(_configs.value.map { if (it.id == configId) it.copy(enabled = enabled) else it })
    }

    /**
     * Puts the addons in [orderedIds], which is the order they will be asked in.
     *
     * The stored list *is* the priority order and needs no rank field to carry
     * it: [active] sorts by [SourceKind.rank] stably, so two sources of the same
     * kind keep the order they are held in here. Writing a rank alongside would
     * be a second source of truth for a fact the list already states, and the two
     * would drift the first time one was written without the other.
     *
     * Ids naming nothing are dropped and addons the caller forgot to mention are
     * appended, so a list that moved on since the drag started reorders what it
     * can rather than deleting the rest. Everything that is not an addon keeps
     * its place, since its rank is decided by its kind and is not the user's to
     * set.
     */
    fun reorderAddons(orderedIds: List<String>) {
        val addons = _configs.value.filter { it.kind.isUserAdded }
        if (addons.size < 2) return
        val byId = addons.associateBy { it.id }
        val moved = orderedIds.mapNotNull(byId::get)
        val missed = addons.filterNot { config -> moved.any { it.id == config.id } }
        val reordered = moved + missed
        if (reordered.map { it.id } == addons.map { it.id }) return
        publish(reordered + _configs.value.filterNot { it.kind.isUserAdded })
    }

    private fun publish(next: List<SourceConfig>, persist: Boolean = true) {
        _configs.value = next
        // Rebuilt against the previous map so an untouched source keeps the
        // instance it already had, rather than being replaced by an
        // identical-but-cold one every time an unrelated row is toggled.
        val previous = instances
        instances = next.associate { config ->
            val existing = previous[config.id]?.takeIf { it.configuredBy(config) }
            config.id to (existing ?: build(config))
        }
        if (persist) writeStored(next)
    }

    /**
     * Health-checks a config that has not been saved — what the editor's Test
     * button asks.
     *
     * Built fresh and thrown away rather than routed through [instances], which
     * hold the *stored* config: testing one of those would report on the old
     * address, which is precisely the state the user is in the middle of
     * correcting.
     */
    suspend fun probeCandidate(config: SourceConfig): SourceHealth = build(config.tidied()).health()

    private fun build(config: SourceConfig): MusicSource = when (config.kind) {
        SourceKind.ADDON -> AddonSource(config)
        // Same protocol, same implementation — the kinds differ only in rank.
        SourceKind.CUSTOM_MODULE -> ModuleSource(config)
        SourceKind.MODULE -> ModuleSource(config)
        SourceKind.JIOSAAVN -> JioSaavnSource(config)
        SourceKind.YOUTUBE -> YouTubeSource(config)
    }

    /**
     * Whether an already-built instance still matches its stored config — false
     * after an edit that changes where it points, which is exactly when the warm
     * instance must be thrown away.
     */
    private fun MusicSource.configuredBy(config: SourceConfig): Boolean =
        this is ConfigBacked && this.config == config

    // ── Track identity ──────────────────────────────────────────────────

    /**
     * A source-backed track's id, as it travels through the queue.
     *
     * Packed into the existing `Song.videoId` rather than added beside it: that
     * field is the app's media id everywhere — the queue, the notification, the
     * history, the like state — and a second identity field would have to be
     * threaded through every one of them, with each place that forgot silently
     * falling back to treating the track as YouTube's.
     */
    fun trackKey(configId: String, trackId: String): String = "$PREFIX$configId$SEPARATOR$trackId"

    /** The `(configId, trackId)` inside a [trackKey], or null for an ordinary YouTube id. */
    fun parseTrackKey(key: String): Pair<String, String>? {
        if (!key.startsWith(PREFIX)) return null
        val body = key.removePrefix(PREFIX)
        val cut = body.indexOf(SEPARATOR)
        if (cut <= 0) return null
        return body.substring(0, cut) to body.substring(cut + SEPARATOR.length)
    }

    // ── Secrets ─────────────────────────────────────────────────────────

    /**
     * The addon's address, read from the secret tier rather than from the stored
     * list.
     *
     * An addon's `baseUrl` can carry the user's token in its path, so the stored
     * [SourceConfig] holds a marker instead of the value and the real address
     * lives in the Keychain. A source whose secret has gone missing — a restore
     * that did not carry it, a user who cleared the Keychain — is not complete,
     * and [isComplete] then keeps it out of every walk rather than having the app
     * try a request to a URL it no longer has.
     */
    internal fun secretAccount(configId: String): String = "source.$configId"

    internal fun baseUrlOf(config: SourceConfig): String {
        if (!config.kind.needsServer) return config.baseUrl
        return PlatformSettings.getSecret(secretAccount(config.id)) ?: config.baseUrl
    }

    internal fun storeBaseUrl(config: SourceConfig, url: String) {
        if (!config.kind.needsServer) return
        PlatformSettings.putSecret(secretAccount(config.id), url.ifBlank { null })
    }

    /**
     * The already-configured source pointing at [url], if there is one.
     *
     * Compared after normalisation rather than on the raw text, which is what
     * makes this catch the cases worth catching: an addon's root and its
     * `manifest.json` are the same server typed two ways, and a trailing slash, a
     * `MANIFEST.JSON` and a differently-cased host are all the same source too.
     *
     * [exceptId] is the source being edited, which is not its own duplicate —
     * without it, saving an existing addon without touching its URL would refuse
     * itself.
     */
    fun duplicateOf(url: String, exceptId: String? = null): SourceConfig? {
        val wanted = canonicalUrl(url)
        if (wanted.isEmpty()) return null
        return _configs.value.firstOrNull {
            it.id != exceptId && canonicalUrl(baseUrlOf(it)) == wanted
        }
    }

    /**
     * A URL reduced to the form two spellings of the same address share.
     *
     * Scheme and host are lowercased because they are case-insensitive; the path
     * deliberately is not, because on this protocol the path can carry a user's
     * token and two tokens differing only in case are two different credentials.
     * Falls back to the trimmed text when the URL will not parse, so a malformed
     * entry still compares equal to itself.
     */
    internal fun canonicalUrl(raw: String): String {
        val trimmed = raw.trim().trimEnd('/')
        if (trimmed.isEmpty()) return ""
        val scheme = trimmed.substringBefore("://", missingDelimiterValue = "").lowercase()
        if (scheme.isEmpty()) return trimmed
        val afterScheme = trimmed.substringAfter("://")
        val authority = afterScheme.substringBefore('/').substringBefore('?')
        val host = authority.substringAfterLast(':').lowercase()
        val port = authority.substringAfterLast(':', "").toIntOrNull()
        val path = afterScheme.substringAfter('/', "").trimEnd('/')
        val query = afterScheme.substringAfter('?', "").takeIf { it.isNotEmpty() }?.let { "?$it" }.orEmpty()
        val defaultPort = if (scheme == "https") 443 else 80
        val portPart = if (port != null && port != defaultPort) ":$port" else ""
        return "$scheme://$host$portPart/$path$query".trimEnd('/').let {
            if (path.isEmpty() && query.isEmpty()) "$scheme://$host$portPart" else it
        }
    }

    /**
     * An addon's base, with either spelling of the same address reduced to one.
     *
     * Strips *any* `.json` suffix and a trailing slash: `https://host`,
     * `https://host/`, `https://host/manifest.json` and `https://host/MANIFEST.JSON`
     * all address one server, and the app appends the paths itself.
     */
    internal fun normalizeAddonBase(raw: String): String {
        val trimmed = raw.trim().trimEnd('/')
        if (trimmed.isEmpty()) return ""
        return if (trimmed.substringAfterLast('/').contains('.')) {
            trimmed.substringBeforeLast('.')
        } else {
            trimmed
        }
    }

    private val BUILT_IN_KINDS = listOf(SourceKind.JIOSAAVN, SourceKind.YOUTUBE)

    private const val KEY_SOURCES = "sources"
    /** One-shot migration: existing users must explicitly opt in again. */
    private const val KEY_JIOSAAVN_OPT_IN_V1 = "jiosaavn_opt_in_v1"
    private const val PREFIX = "src:"
    private const val SEPARATOR = "::"
}

/**
 * One configured source: which protocol, which server.
 *
 * [baseUrl] is stored in the secret tier rather than here — see
 * [SourceRegistry.baseUrlOf] — because on this protocol it can carry the user's
 * token in its path, which makes it a credential and not a preference. The field
 * remains, and remains readable, so a config decoded from an older build — or
 * one that has no secret yet — still works.
 */
@Serializable
data class SourceConfig(
    val id: String = newSourceId(),
    val kind: SourceKind,
    /** What the user called it. Blank falls back to the server's host, or the kind's own label. */
    val label: String = "",
    val baseUrl: String = "",
    /** JioSaavn is opt-in because catalogue matches can select the wrong recording. */
    val enabled: Boolean = kind != SourceKind.JIOSAAVN,
) {
    /** What the sources screen and the player show. Never blank. */
    val displayName: String
        get() = label.ifBlank {
            SourceRegistry.baseUrlOf(this).takeIf { it.isNotBlank() }
                ?.let { hostOf(it) }
                ?: kind.label
        }

    /**
     * Whether this has enough filled in to be worth contacting at all.
     *
     * A server-backed source whose secret has gone missing answers false, so a
     * restore that did not carry the Keychain leaves the source listed but out of
     * every walk, rather than the app trying a request to a URL it no longer has.
     */
    val isComplete: Boolean
        get() = !kind.needsServer || SourceRegistry.baseUrlOf(this).isNotBlank()
}

private fun hostOf(url: String): String? = runCatching {
    val afterScheme = url.substringAfter("://", missingDelimiterValue = "")
    afterScheme.substringBefore('/').substringBefore('?').substringAfterLast(':').ifEmpty { null }
}.getOrNull()

private fun newSourceId(): String {
    val alphabet = "0123456789abcdef"
    return buildString(32) { repeat(32) { append(alphabet[Random.nextInt(alphabet.length)]) } }
}

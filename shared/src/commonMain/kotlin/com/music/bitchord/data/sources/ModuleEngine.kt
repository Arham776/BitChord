package com.music.bitchord.data.sources

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.concurrent.Volatile
import kotlin.coroutines.resume

/**
 * The JavaScript half of the legacy module protocol, as a platform seam.
 *
 * A module index lists plugin descriptors; each ships a JavaScript file exporting
 * `searchTracks()` and `getTrackStreamUrl()`, and the app runs them in a sandbox
 * with a wired-in `fetch()` and nothing else. That engine is a platform
 * dependency — QuickJS upstream, **JavaScriptCore** here — so like
 * [CipherUnlockBridge][com.music.bitchord.data.innertube.CipherUnlockBridge] the
 * execution is a Swift implementation registered at launch and the portable layer
 * waits on a callback.
 *
 * ## Why the seam is here rather than spread through [ModuleSource]
 *
 * Everything above the engine *is* portable and lives in [ModuleSource]: fetching
 * the index, deciding which entries to ask, the fan-out and its `waitForAll`
 * rule, and the refusal rules on what comes back. Only "run this script and call
 * this function" needs the platform, and keeping that the only platform-dependent
 * piece is what lets the rest of the source layer be shared.
 *
 * ## What is not implemented here
 *
 * The engine itself, and the three refusals that belong to it: a module that
 * answers a *malformed* document, one that hands back a URL which turns out to be
 * [AddonSource]'s `isEncrypted` case, and one that returns something
 * unplayable. On Apple the wiring is `ModuleJsHost`, which already exists and
 * already loads module scripts for the port's earlier ad-hoc path — wiring it to
 * this seam is what turns that path into a real source.
 *
 * Until it is wired, a module search returns nothing and the source reports
 * `Rejected`, which is the honest answer: an index that is reachable but cannot
 * have its scripts run is a configuration this build cannot satisfy, not an outage
 * to retry.
 */
object ModuleEngine {

    interface Impl {
        /** Tracks the module holds for [query], as raw JSON rows. */
        fun search(moduleId: String, scriptUrl: String, query: String, tier: String?, callback: RowsCallback)

        /** A playable URL for one of the module's own track ids, as raw JSON. */
        fun stream(moduleId: String, scriptUrl: String, trackId: String, tier: String?, callback: StreamCallback)
    }

    fun interface RowsCallback {
        fun onResult(json: String?, error: String?)
    }

    fun interface StreamCallback {
        fun onResult(json: String?, error: String?)
    }

    @Volatile
    private var impl: Impl? = null

    fun setImpl(value: Impl?) {
        impl = value
    }

    /** Loaded module scripts, by module id, for [forget]. */
    private val loaded = mutableSetOf<String>()

    internal suspend fun search(entry: ModuleEntry, query: String, tier: String?): List<ModuleRow> {
        val bridge = impl ?: return emptyList()
        loaded += entry.id
        val raw: String? = suspendCancellableCoroutine { cont ->
            val done = RowsCallback { json, _ -> if (cont.isActive) cont.resume(json) }
            bridge.search(entry.id, entry.download, query, tier, done)
        }
        return raw?.let { ModuleEngineJson.decodeRows(it) }.orEmpty()
    }

    internal suspend fun stream(
        entry: ModuleEntry,
        trackId: String,
        tier: String?,
    ): ModuleStream? {
        val bridge = impl ?: return null
        val raw: String? = suspendCancellableCoroutine { cont ->
            val done = StreamCallback { json, _ -> if (cont.isActive) cont.resume(json) }
            bridge.stream(entry.id, entry.download, trackId, tier, done)
        }
        return raw?.let { ModuleEngineJson.decodeStream(it) }
    }

    /** Drop a module's loaded script — the configuration it was loaded for is gone. */
    internal fun forget(configId: String) {
        loaded -= configId
    }
}

package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.Song
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Swift-facing coroutine bridge over the suspend innertube API.
 *
 * Spec §1.1 routes suspend/Flow exposure through KMP-NativeCoroutines; for
 * the v1 search path this object uses the same wrap-don't-export principle
 * with an explicit callback interface, which ObjC exports as a protocol
 * without extra tooling. Results cross the bridge as JSON so the Swift side
 * stays free of Kotlin collection types.
 */
object SearchBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }
    private val songListSerializer = ListSerializer(Song.serializer())

    fun interface SearchCallback {
        /** Called on a background thread with either [json] or [message]. */
        fun onResult(json: String?, message: String?)
    }

    fun search(query: String, scope: String, callback: SearchCallback) {
        bridgeScope.launch {
            try {
                val response = Innertube.search(query, InnertubeParser.paramsFor(scope))
                val songs = InnertubeParser.parseSearchSongs(response)
                callback.onResult(json.encodeToString(songListSerializer, songs), null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}

package com.music.bitchord.data.library

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.settings.AppSettings
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Swift-facing seam over the local library's ordering and filtering.
 *
 * Narrow on purpose: the host already has the tracks, because it scanned them.
 * What crosses is the tracks as small documents in and one ordered list out. The
 * alternative — having the host sort with its own comparators — is how the
 * ordering ends up subtly different from the one the settings screen names, and
 * neither is tested.
 */
object LocalLibraryBridge {

    private val json = Json { ignoreUnknownKeys = true }

    fun interface SortCallback {
        fun onResult(order: String, viewType: String)
    }

    fun interface SetSortCallback {
        fun onResult(ok: Boolean)
    }

    /**
     * The tracks narrowed by [query] and put in [order], as a document.
     *
     * **Synchronous, deliberately.** This is in-memory work over a list the host
     * already holds — a few hundred rows at most, and no network behind it — so a
     * coroutine would be ceremony around arithmetic. It was asynchronous in an
     * earlier version, which forced the host to read the answer out of a captured
     * variable it had not been given yet: a race that returns the unsorted list
     * about half the time and is invisible when it does.
     *
     * The result is a document rather than a list of paths because a large scan
     * does not belong in a call signature.
     */
    fun view(tracksJson: String, order: String, query: String): String {
        val tracks = decodeTracks(tracksJson)
        val resolved = resolveSort(order)
        return encodeTracks(
            if (resolved == null) tracks.filter { it.matchesSearch(query) } else tracks.libraryView(resolved, query),
        )
    }

    /** The sort and view type in force, for the menu to reflect. */
    fun currentSort(callback: SortCallback) {
        callback.onResult(
            AppSettings.localLibrarySort.value.name,
            AppSettings.localLibraryViewType.value.name,
        )
    }

    fun setSort(order: String, callback: SetSortCallback) {
        val resolved = resolveSort(order) ?: return callback.onResult(false)
        AppSettings.setLocalLibrarySort(resolved)
        callback.onResult(true)
    }

    fun setViewType(viewType: String, callback: SetSortCallback) {
        val resolved = resolveViewType(viewType) ?: return callback.onResult(false)
        AppSettings.setLocalLibraryViewType(resolved)
        callback.onResult(true)
    }

    /** A human name for each order, so the host does not carry its own list. */
    fun sortLabelsJson(): String = LocalMusicSort.entries.joinToString(
        ",", prefix = "[", postfix = "]",
    ) { """{"name":${quote(it.name)},"label":${quote(it.label)}}""" }

    // ---- Encoding ---------------------------------------------------------

    private fun encodeTracks(tracks: List<LocalSong>): String = tracks.joinToString(
        ",", prefix = "[", postfix = "]",
    ) { track ->
        """{"path":${quote(track.path)},"title":${quote(track.title)},""" +
            """"artist":${quote(track.artist)},"album":${quote(track.album)},""" +
            """"durationSeconds":${track.durationSeconds},""" +
            """"dateAddedSeconds":${track.dateAddedSeconds ?: "null"},""" +
            """"dateModifiedSeconds":${track.dateModifiedSeconds ?: "null"}}"""
    }

    private fun decodeTracks(document: String): List<LocalSong> = runCatching {
        val array = json.parseToJsonElement(document) as? JsonArray ?: return emptyList()
        array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val path = obj.string("path") ?: return@mapNotNull null
            LocalSong(
                path = path,
                title = obj.string("title").orEmpty(),
                artist = obj.string("artist").orEmpty(),
                album = obj.string("album").orEmpty(),
                durationSeconds = obj.double("durationSeconds") ?: 0.0,
                dateAddedSeconds = obj.long("dateAddedSeconds"),
                dateModifiedSeconds = obj.long("dateModifiedSeconds"),
            )
        }
    }.getOrElse {
        DebugLog.w("local library document unreadable: ${it.message}")
        emptyList()
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }

    private fun JsonObject.long(key: String): Long? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        return primitive.contentOrNull?.toLongOrNull() ?: primitive.longOrNullCompat()
    }

    private fun JsonPrimitive.longOrNullCompat(): Long? =
        contentOrNull?.toDoubleOrNull()?.toLong()

    private fun JsonObject.double(key: String): Double? {
        val primitive = this[key] as? JsonPrimitive ?: return null
        return primitive.contentOrNull?.toDoubleOrNull() ?: primitive.doubleOrNull
    }

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.let {
            it.contentOrNull?.toBooleanStrictOrNull() ?: it.booleanOrNull
        }

    private fun quote(value: String): String = buildString {
        append('"')
        value.forEach { ch ->
            when {
                ch == '"' -> append("\\\"")
                ch == '\\' -> append("\\\\")
                ch == '\n' -> append("\\n")
                ch == '\r' -> append("\\r")
                ch == '\t' -> append("\\t")
                ch.code < 0x20 -> append("\\u").append(ch.code.toString(16).padStart(4, '0'))
                else -> append(ch)
            }
        }
        append('"')
    }

    private fun resolveSort(name: String): LocalMusicSort? =
        LocalMusicSort.entries.firstOrNull { it.name == name.trim() }

    private fun resolveViewType(name: String): LocalViewType? =
        LocalViewType.entries.firstOrNull { it.name == name.trim() }

}

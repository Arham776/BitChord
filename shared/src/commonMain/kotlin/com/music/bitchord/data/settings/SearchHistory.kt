package com.music.bitchord.data.settings


import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Port of upstream `data/settings/SearchHistory.kt` — what's been searched for
 * lately, kept on this device only, stored as JSON so a query can contain any
 * character. `multiplatform-settings` (NSUserDefaults) backing per spec §1.3.
 */
object SearchHistory {

    /** Deep enough to be useful, shallow enough that the list stays scannable. */
    private const val MAX_ENTRIES = 20
    private const val KEY_HISTORY = "search_history"

    private val settings = PlatformSettings
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(String.serializer())

    private val _recent = MutableStateFlow(load())
    /** Most recent first. */
    val recent: StateFlow<List<String>> = _recent.asStateFlow()

    private fun load(): List<String> = runCatching {
        json.decodeFromString(serializer, settings.getString(KEY_HISTORY, "[]"))
    }.getOrDefault(emptyList())

    /** Records [query], or moves it back to the top if it's already there. */
    fun record(query: String) {
        val term = query.trim()
        if (term.isEmpty()) return
        val deduped = _recent.value.filterNot { it.equals(term, ignoreCase = true) }
        save((listOf(term) + deduped).take(MAX_ENTRIES))
    }

    fun remove(query: String) {
        save(_recent.value.filterNot { it.equals(query, ignoreCase = true) })
    }

    fun clear() = save(emptyList())

    private fun save(value: List<String>) {
        _recent.value = value
        settings.putString(KEY_HISTORY, json.encodeToString(serializer, value))
    }
}

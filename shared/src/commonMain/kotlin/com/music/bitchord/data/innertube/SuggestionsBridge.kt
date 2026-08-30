package com.music.bitchord.data.innertube

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Swift-facing bridge for search typeahead suggestions.
 */
object SuggestionsBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface SuggestionsCallback {
        fun onResult(json: String?, message: String?)
    }

    fun suggest(input: String, callback: SuggestionsCallback) {
        bridgeScope.launch {
            try {
                val response = Innertube.searchSuggestions(input)
                val suggestions = InnertubeParser.parseSearchSuggestions(response)
                callback.onResult(
                    json.encodeToString(ListSerializer(String.serializer()), suggestions),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}

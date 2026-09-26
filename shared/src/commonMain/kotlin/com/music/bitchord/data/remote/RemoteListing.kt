package com.music.bitchord.data.remote

import com.music.bitchord.data.model.UiState

/**
 * What a remote library page shows for a listing.
 *
 * Port of upstream `data/remote/RemoteListing.kt`.
 *
 * The reason this is one function rather than something each screen writes for itself
 * is the sentence it produces: a share that answers with an error is **not** an empty
 * share, and "no audio files" would send somebody hunting through folder paths for a
 * password problem. An empty listing and a failed one read identically otherwise, and
 * the difference is the whole content of this feature.
 */
object RemoteListing {

    /**
     * @param emptyMessage what to say when the server answered and there is nothing in
     *   it. Passed in rather than fixed, because a share that is empty and a folder
     *   with no audio in it are different sentences.
     */
    fun <T> state(listing: Result<List<T>>, emptyMessage: String): UiState<List<T>> =
        listing.fold(
            onSuccess = { items ->
                if (items.isEmpty()) UiState.Error(emptyMessage) else UiState.Success(items)
            },
            onFailure = {
                // The class name is a last resort, and a bad one: it is a name nobody
                // asked for. `::class` rather than `javaClass`, which is JVM-only.
                UiState.Error(it.message?.takeIf(String::isNotBlank) ?: it::class.simpleName.orEmpty())
            },
        )
}

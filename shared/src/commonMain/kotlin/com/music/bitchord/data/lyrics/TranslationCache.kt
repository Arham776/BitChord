package com.music.bitchord.data.lyrics

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The bounded cache behind a translation.
 *
 * A seam rather than an implementation because the policy and the storage are
 * genuinely different jobs: [get] and [put] are called from common code that has
 * no filesystem, and the eviction ceiling is a number the policy owns.
 *
 * Two tiers, because the two access patterns are nothing alike. Repeat listens
 * hit the same lyric within seconds and want it back without touching a disk;
 * everything else is a cold start days later, where a few kilobytes of read is
 * worth far more than the bytes.
 */
internal object TranslationCache {

    private val json = Json { ignoreUnknownKeys = true }

    /** How many translations are held in memory. */
    private const val MEMORY_ENTRIES = 12

    private val memory = BoundedLru<String, String>(MEMORY_ENTRIES)

    fun get(key: String): CachedTranslation? {
        memory[key]?.let { document ->
            return runCatching {
                json.decodeFromString(CachedTranslation.serializer(), document)
            }.getOrNull()
        }
        val stored = read(key) ?: return null
        memory[key] = stored
        return runCatching {
            json.decodeFromString(CachedTranslation.serializer(), stored)
        }.getOrNull()
    }

    fun put(key: String, entry: CachedTranslation) {
        val document = runCatching {
            json.encodeToString(CachedTranslation.serializer(), entry)
        }.getOrNull() ?: return
        memory[key] = document
        write(key, document)
    }

    fun clear() {
        memory.clear()
        removeAll()
    }

    /** Visible for tests. */
    internal fun size(): Int = memory.size
}

/**
 * One cached translation, as it is stored.
 *
 * Carries the policy version that produced it, so an app update that changes what
 * a good translation looks like can tell a stale answer from a current one rather
 * than serving it and looking like it worked.
 */
@Serializable
internal data class CachedTranslation(
    val version: Int,
    val sourceLanguage: String,
    val targetLanguage: String,
    val texts: List<String>,
)

// The disk tier. Memory is portable; where a file goes is not.
internal expect fun read(key: String): String?
internal expect fun write(key: String, document: String)
internal expect fun removeAll()

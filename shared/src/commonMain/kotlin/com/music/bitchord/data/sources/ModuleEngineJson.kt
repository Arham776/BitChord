package com.music.bitchord.data.sources

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Decoding for what a module's JavaScript returns.
 *
 * Separate from [ModuleEngine] because the shapes are the *issuer's* choice, not
 * the protocol's: a module is a third-party script and there is no schema to hold
 * it to. Every field is therefore read defensively and from several plausible
 * spellings, and a row that cannot be understood is dropped rather than
 * half-populated — a row with a title and no id cannot be streamed later, and
 * admitting it would put a dead entry in the queue.
 */
internal object ModuleEngineJson {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }

    fun decodeRows(raw: String): List<ModuleRow> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull() ?: return emptyList()
        val elements = when (root) {
            is JsonArray -> root
            // A module that returns a single object where a list was expected is
            // common enough to be worth accepting rather than showing the listener
            // an empty result for a search that plainly found something.
            is JsonObject -> (root["tracks"] as? JsonArray)
                ?: (root["results"] as? JsonArray)
                ?: listOf(root)
            else -> return emptyList()
        }
        return elements.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id", "trackId", "track_id", "uid") ?: return@mapNotNull null
            val title = obj.string("title", "name", "track") ?: return@mapNotNull null
            ModuleRow(
                id = id,
                title = title,
                artist = obj.string("artist", "artists", "author", "albumArtist").orEmpty(),
                album = obj.string("album", "albumName"),
                durationSec = obj.int("durationSec", "duration", "length", "seconds"),
                artworkUrl = obj.string("artworkUrl", "artwork", "cover", "image", "thumbnail"),
                codec = obj.string("codec", "format", "container"),
                kbps = obj.int("kbps", "bitrate", "bitrateKbps"),
                sampleRateHz = obj.int("sampleRateHz", "sampleRate", "samplerate"),
                bitDepth = obj.int("bitDepth", "bits"),
                explicit = obj.bool("explicit", "isExplicit") ?: false,
                lossless = (obj.bool("lossless", "isLossless") ?: false) ||
                    (obj.bool("hiRes", "isHiRes") ?: false),
            )
        }
    }

    fun decodeStream(raw: String): ModuleStream? {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull() as? JsonObject
            ?: return null
        val url = root.string("url", "streamUrl", "stream_url") ?: return null
        return ModuleStream(
            url = url,
            codec = root.string("codec", "format", "container"),
            kbps = root.int("kbps", "bitrate", "bitrateKbps"),
            sampleRateHz = root.int("sampleRateHz", "sampleRate"),
            bitDepth = root.int("bitDepth", "bits"),
            mimeType = root.string("mimeType", "mime", "contentType"),
            headers = (root["headers"] as? JsonObject)
                ?.entries
                ?.mapNotNull { (key, value) ->
                    (value as? JsonPrimitive)?.contentOrNull?.let { key to it }
                }
                ?.toMap()
                .orEmpty(),
            belowRequest = root.bool("belowRequest", "below_request") ?: false,
            durationSec = root.int("durationSec", "duration"),
        )
    }

    private fun JsonObject.string(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
        (get(key) as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
    }

    private fun JsonObject.int(vararg keys: String): Int? = keys.firstNotNullOfOrNull { key ->
        val primitive = get(key) as? JsonPrimitive ?: return@firstNotNullOfOrNull null
        primitive.intOrNull ?: primitive.contentOrNull?.toDoubleOrNull()?.toInt()
    }

    private fun JsonObject.bool(vararg keys: String): Boolean? = keys.firstNotNullOfOrNull { key ->
        val primitive = get(key) as? JsonPrimitive ?: return@firstNotNullOfOrNull null
        primitive.booleanOrNull ?: primitive.contentOrNull?.lowercase()?.let {
            when (it) {
                "true", "1", "yes" -> true
                "false", "0", "no" -> false
                else -> null
            }
        }
    }
}

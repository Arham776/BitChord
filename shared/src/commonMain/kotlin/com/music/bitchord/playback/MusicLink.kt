package com.music.bitchord.playback

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Port of upstream `playback/MusicLink.kt`, split per spec §1.3: URL parsing
 * and pending-request state are common (this file); the intake seam is
 * Apple-side — SwiftUI `onOpenURL` (iOS) and `NSAppleEventManager` URL events
 * (macOS) call [submit] with the incoming URL or shared text.
 */

/** What a link from outside the app turned out to be asking for. */
sealed interface LinkRequest {
    /** A song, by video id — `watch?v=`, a `youtu.be` short link, a Short. */
    data class Track(val videoId: String) : LinkRequest

    /** An album, playlist or artist page, by browse id. */
    data class Page(val browseId: String) : LinkRequest

    /**
     * Words rather than an id: "play Blinding Lights", or a shared search URL.
     * [play] separates instruction (start the best match) from page (show a list).
     */
    data class Search(val query: String, val play: Boolean) : LinkRequest

    /** "Play music", with nothing said about what. */
    data object Resume : LinkRequest
}

object MusicLink {

    private val _pending = MutableStateFlow<LinkRequest?>(null)

    /** The outstanding request, or null. Cleared by [handled]. */
    val pending: StateFlow<LinkRequest?> = _pending.asStateFlow()

    /** Apple intake: a URL event or a share-sheet text arrived. */
    fun submitUrl(url: String?): Boolean {
        val request = url?.let { parseUrlString(it) } ?: return false
        _pending.value = request
        return true
    }

    /** Apple intake: shared text from the system share sheet. */
    fun submitSharedText(text: String?): Boolean {
        val request = text?.let(::firstUrl)?.let(::parseUrlString) ?: return false
        _pending.value = request
        return true
    }

    /** Voice "play <something>" / "play music" intake. */
    fun submitVoiceQuery(query: String): Boolean {
        val trimmed = query.trim()
        val request =
            if (trimmed.isEmpty()) LinkRequest.Resume else LinkRequest.Search(trimmed, play = true)
        _pending.value = request
        return true
    }

    /**
     * Called once the request has actually been acted on — by whoever acted,
     * not by whoever set it, so a request left standing is never served twice.
     */
    fun handled() {
        _pending.value = null
    }

    /**
     * What a YouTube or YouTube Music URL points at, or null for one this app
     * has nothing to show for. Forgiving about the host: `music.youtube.com`,
     * `www.youtube.com`, `m.youtube.com` and `youtu.be` all address the same
     * catalogue with the same ids.
     */
    fun parseUrlString(raw: String): LinkRequest? {
        val uri = raw.trim()
        if (uri.isEmpty()) return null
        val hostPart = uri
            .removePrefix("https://")
            .removePrefix("http://")
            .substringBefore('/')
            .lowercase()
            .removePrefix("www.")
        val path = uri
            .removePrefix("https://")
            .removePrefix("http://")
            .substringAfter('/')
            .substringBefore('?')
        val query = uri.substringAfter('?', "")
        val segments = path.split('/').filter { it.isNotEmpty() }

        if (hostPart == "youtu.be") {
            return segments.firstOrNull()?.let(::track)
        }
        if (hostPart != "youtube.com" && hostPart != "music.youtube.com" && hostPart != "m.youtube.com") {
            return null
        }
        val list = queryParameter(query, "list")?.trim().orEmpty()
        return when (segments.firstOrNull()) {
            "watch" -> queryParameter(query, "v")?.let(::track) ?: playlist(list)
            "playlist" -> playlist(list)
            "shorts", "embed", "v" -> segments.getOrNull(1)?.let(::track)
            "channel", "browse" -> segments.getOrNull(1)?.takeIf { it.isNotBlank() }
                ?.let(LinkRequest::Page)
            "search" -> queryParameter(query, "q")?.trim()?.takeIf { it.isNotEmpty() }
                ?.let { LinkRequest.Search(it, play = false) }
            else -> list.takeIf { it.isNotEmpty() }?.let { playlist(it) }
        }
    }

    private fun queryParameter(query: String, name: String): String? =
        query.split('&')
            .mapNotNull {
                val pair = it.split('=', limit = 2)
                if (pair.size == 2) pair[0] to pair[1] else null
            }
            .firstOrNull { (key, _) -> key == name }
            ?.second
            ?.let(::percentDecode)

    /** `application/x-www-form-urlencoded` decode for query values. */
    private fun percentDecode(raw: String): String {
        if ('%' !in raw && '+' !in raw) return raw
        val bytes = ArrayList<Byte>(raw.length)
        var i = 0
        while (i < raw.length) {
            when (val c = raw[i]) {
                '+' -> { bytes.add(' '.code.toByte()); i++ }
                '%' -> {
                    if (i + 2 < raw.length + 1 && i + 2 <= raw.length - 1 + 1) {
                        val hex = raw.substringOrNull(i + 1, i + 3)
                        val value = hex?.toIntOrNull(16)
                        if (value != null) {
                            bytes.add(value.toByte())
                            i += 3
                        } else {
                            bytes.add(c.code.toByte()); i++
                        }
                    } else {
                        bytes.add(c.code.toByte()); i++
                    }
                }
                else -> { bytes.add(c.code.toByte()); i++ }
            }
        }
        return bytes.toByteArray().decodeToString()
    }

    private fun String.substringOrNull(start: Int, end: Int): String? =
        if (start in indices && end <= length && start < end) substring(start, end) else null

    private fun track(videoId: String): LinkRequest.Track? =
        videoId.trim().takeIf { it.isNotEmpty() }?.let(LinkRequest::Track)

    /**
     * A playlist id as the browse id its page is fetched under — `VL` is the
     * prefix every playlist browse carries, an album's `OLAK5uy_…` share id
     * included.
     */
    private fun playlist(listId: String): LinkRequest.Page? {
        if (listId.isEmpty()) return null
        return LinkRequest.Page(if (listId.startsWith("VL")) listId else "VL$listId")
    }

    /** The first http(s) URL in shared text. */
    private fun firstUrl(text: String): String? =
        URL_IN_TEXT.find(text)?.value

    private val URL_IN_TEXT = Regex("""https?://\S+""")
}

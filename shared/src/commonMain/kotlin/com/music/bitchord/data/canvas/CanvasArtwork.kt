package com.music.bitchord.data.canvas

/**
 * A looping video that stands in for a track's cover art — Spotify Canvas or
 * Apple Music motion artwork. [fallbackUrl] is a second rendition of the same
 * clip, tried once if the preferred one will not decode.
 */
data class CanvasArtworkDto(
    val url: String,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val source: String,
    val fallbackUrl: String? = null,
) {
    fun matches(wantTitle: String, wantArtist: String, wantAlbum: String?): Boolean {
        val titleOk = title == null || wantTitle.isBlank() || when (source) {
            // Community entries include featured artists in the song title,
            // while YouTube Music may report them as separate credits.
            "community" -> title.communityTitleKey() == wantTitle.communityTitleKey()
            else -> title.normalizeForMatch() == wantTitle.normalizeForMatch()
        }
        val titleArtists = splitArtists(wantArtist)
        val ourArtists = splitArtists(artist.orEmpty())
        val artistOk = artist == null || wantArtist.isBlank() || when (source) {
            // The community index credits the primary artist, not necessarily
            // every featured performer listed by the playing source.
            "community" -> titleArtists.isNotEmpty() && ourArtists.isNotEmpty() &&
                titleArtists.any { want -> ourArtists.any { it == want } }
            else -> titleArtists.isNotEmpty() && ourArtists.isNotEmpty() &&
                titleArtists.all { want -> ourArtists.any { it == want } }
        }
        val albumOk = album.isNullOrBlank() || wantAlbum.isNullOrBlank() ||
            album.normalizeForMatch() == wantAlbum.normalizeForMatch()
        return titleOk && artistOk && albumOk
    }
}

/** Community song names sometimes append featured performers to the title. */
internal fun String.communityTitleKey(): String = normalizeForMatch()
    .replace(Regex("\\s+(?:feat|featuring|ft)\\s+.+$"), "")
    .trim()

internal const val CANVAS_UA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/122.0.0.0 Safari/537.36"

/** Fold case, punctuation and common diacritics so catalogue names can match. */
internal fun String.normalizeForMatch(): String =
    lowercase()
        .replace(Regex("[àáâãäåāăą]"), "a")
        .replace(Regex("[èéêëēĕėęě]"), "e")
        .replace(Regex("[ìíîïĩīĭįı]"), "i")
        .replace(Regex("[òóôõöōŏő]"), "o")
        .replace(Regex("[ùúûüũūŭůűų]"), "u")
        .replace(Regex("[ýÿŷ]"), "y")
        .replace(Regex("[çćĉċč]"), "c")
        .replace(Regex("[ñńņň]"), "n")
        .replace("æ", "ae")
        .replace("œ", "oe")
        .replace("ß", "ss")
        .replace(Regex("[^a-z0-9\\s]"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

internal fun splitArtists(raw: String): List<String> =
    raw.split(ARTIST_SEPARATORS)
        .map { it.normalizeForMatch() }
        .filter { it.isNotBlank() }

private val ARTIST_SEPARATORS = Regex(
    "(?:\\s*,\\s*|\\s*&\\s*|\\s+×\\s+|\\s+x\\s+|\\bfeat\\.?\\b|\\bft\\.?\\b|\\bfeaturing\\b|\\bwith\\b)",
    RegexOption.IGNORE_CASE,
)

/** YouTube Music packaging that catalogue searches never see. */
internal fun String.cleanedForCanvas(): String = replace(CANVAS_NOISE, " ")
    .substringBefore(" | ")
    .replace(Regex("\\s+"), " ")
    .trim()
    .ifBlank { this }

private val CANVAS_NOISE = Regex(
    """\((?:from|official|lyrical|video|audio)[^)]*\)|\[[^]]*]|""" +
        """\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b""",
    RegexOption.IGNORE_CASE,
)

internal expect fun canvasNowMs(): Long

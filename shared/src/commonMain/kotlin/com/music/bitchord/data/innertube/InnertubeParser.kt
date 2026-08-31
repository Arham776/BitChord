package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.Account
import com.music.bitchord.data.model.BrowseItem
import com.music.bitchord.data.model.BrowseType
import com.music.bitchord.data.model.HomeShelf
import com.music.bitchord.data.model.LibraryState
import com.music.bitchord.data.model.LikeStatus
import com.music.bitchord.data.model.SearchFilter
import com.music.bitchord.data.model.SearchResult
import com.music.bitchord.data.model.ShelfItem
import com.music.bitchord.data.model.Song
import com.music.bitchord.data.model.SongMenu
import com.music.bitchord.data.model.UserPlaylist
import com.music.bitchord.data.settings.AppSettings
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Port of upstream `data/innertube/InnertubeParser.kt` — the search subset.
 * Search results are heterogeneous: songs carry a videoId, albums/artists/
 * playlists carry a browseId plus a page type, both arriving as
 * `musicResponsiveListItemRenderer`, so each row is classified on the way out.
 */
object InnertubeParser {

    fun parseSearchSongs(response: JsonObject): List<Song> =
        parseSearch(response).filterIsInstance<SearchResult.Track>().map { it.song }

    fun parseSearch(response: JsonObject): List<SearchResult> {
        val rows = collectRenderers(response, "musicResponsiveListItemRenderer")
        val seen = HashSet<String>()
        return rows.mapNotNull { renderer ->
            // Browse rows first: an album row also carries a "play album"
            // videoId in its overlay, so a track-first test misreads every
            // album as a single song.
            parseBrowseItem(renderer)?.let { item ->
                return@mapNotNull if (seen.add("b:${item.browseId}")) {
                    SearchResult.Browse(item)
                } else {
                    null
                }
            }
            parseResponsiveListItem(renderer)?.let { song ->
                if (song.isVideo && !AppSettings.convertVideoToAudio.value) return@mapNotNull null
                if (seen.add("v:${song.videoId}")) SearchResult.Track(song) else null
            }
        }
    }

    fun parseSearchSuggestions(response: JsonObject): List<String> =
        collectRenderers(response, "searchSuggestionRenderer")
            .mapNotNull { renderer ->
                val query = renderer.o("navigationEndpoint").o("searchEndpoint").s("query")
                    ?: renderer.o("suggestion").runs()
                query.takeIf { it.isNotBlank() }
            }
            .distinct()

    /** Depth-first collection of a named renderer, preserving document order. */
    private fun collectRenderers(root: JsonElement, name: String): List<JsonObject> {
        val out = mutableListOf<JsonObject>()
        fun walk(node: JsonElement) {
            when (node) {
                is JsonObject -> {
                    (node[name] as? JsonObject)?.let(out::add)
                    node.values.forEach(::walk)
                }
                is JsonArray -> node.forEach(::walk)
                else -> Unit
            }
        }
        walk(root)
        return out
    }

    private fun parseBrowseItem(renderer: JsonObject): BrowseItem? {
        val endpoint = renderer.o("navigationEndpoint").o("browseEndpoint") ?: return null
        val browseId = endpoint.s("browseId") ?: return null
        val pageType = endpoint.o("browseEndpointContextSupportedConfigs")
            .o("browseEndpointContextMusicConfig").s("pageType").orEmpty()

        val columns = renderer.a("flexColumns").orEmpty()
        val title = columns.getOrNull(0)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if (title.isBlank()) return null
        val subtitle = columns.getOrNull(1)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if (VIDEO_WORD.containsMatchIn(title) || VIDEO_WORD.containsMatchIn(subtitle)) return null

        return BrowseItem(
            browseId = browseId,
            title = title,
            subtitle = subtitle,
            thumbnailUrl = renderer.o("thumbnail").o("musicThumbnailRenderer")
                .o("thumbnail").a("thumbnails").best(),
            type = when {
                "ALBUM" in pageType -> BrowseType.ALBUM
                "ARTIST" in pageType -> BrowseType.ARTIST
                "PLAYLIST" in pageType -> BrowseType.PLAYLIST
                else -> BrowseType.OTHER
            },
        )
    }

    /**
     * One track row. [fallback] is what the page it came from is billed to —
     * see [pageCredit] — and is used only where the row itself says nothing.
     */
    private fun parseResponsiveListItem(
        renderer: JsonObject?,
        fallback: Credits = Credits(),
    ): Song? {
        if (renderer == null) return null
        val videoId = renderer.o("playlistItemData").s("videoId")
            ?: renderer.o("overlay")
                .o("musicItemThumbnailOverlayRenderer").o("content")
                .o("musicPlayButtonRenderer").o("playNavigationEndpoint")
                .o("watchEndpoint").s("videoId")
            ?: return null

        val columns = renderer.a("flexColumns").orEmpty()
        val title = columns.getOrNull(0)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if (title.isBlank()) return null

        val subtitle = columns.getOrNull(1)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        val parts = subtitle.split(" • ").filter { it.isNotBlank() }
        val duration = parts.lastOrNull()?.takeIf { it.matches(DURATION) }
        val rowType = parts.firstOrNull { it.lowercase() in TYPE_WORDS }?.lowercase()
        // A track row on an album lists its play count where a search row
        // lists the artist, so a segment that reads as a tally is no credit.
        val artist = parts.firstOrNull {
            !it.matches(DURATION) && it.lowercase() !in TYPE_WORDS && !it.matches(TALLY)
        }

        // The artist/album names in the subtitle carry browse endpoints; pull
        // them out so rows know where their pages are.
        val credits = creditsOf(
            columns.flatMap {
                it.o("musicResponsiveListItemFlexColumnRenderer").o("text").a("runs").orEmpty()
            },
        )

        val thumbnails = renderer.o("thumbnail").o("musicThumbnailRenderer")
            .o("thumbnail").a("thumbnails")

        return Song(
            videoId = videoId,
            title = title,
            // The run that links to an artist page is the authoritative
            // credit; the "All" tab often lists only "Song • 4:30" otherwise,
            // and an album's own rows carry no credit at all — the release is
            // billed once, in the header the row hangs under.
            artist = credits.artistName?.takeIf { it.isNotBlank() }
                ?: artist
                ?: fallback.artistName
                ?: "Unknown artist",
            thumbnailUrl = thumbnails.best(),
            durationText = duration,
            artistId = credits.artistId ?: fallback.artistId,
            albumId = credits.albumId ?: fallback.albumId,
            albumName = credits.albumName ?: fallback.albumName,
            // Only playlist rows carry one — absent on an album or search hit.
            setVideoId = renderer.o("playlistItemData").s("playlistSetVideoId"),
            // A music-video upload gives itself away with widescreen art
            // where a catalogue track has square cover art.
            isVideo = rowType == "video" || thumbnails.isNotSquare(),
        )
    }

    /** The artist / album pages a run list links out to, and their names. */
    internal data class Credits(
        val artistId: String? = null,
        val artistName: String? = null,
        val albumId: String? = null,
        val albumName: String? = null,
    )

    private fun creditsOf(runs: List<JsonElement>): Credits {
        var credits = Credits()
        runs.forEach { run ->
            val browse = run.o("navigationEndpoint").o("browseEndpoint")
            val id = browse.s("browseId") ?: return@forEach
            val pageType = browse.o("browseEndpointContextSupportedConfigs")
                .o("browseEndpointContextMusicConfig").s("pageType").orEmpty()
            credits = when {
                "ARTIST" in pageType && credits.artistId == null ->
                    credits.copy(artistId = id, artistName = run.s("text"))
                "ALBUM" in pageType && credits.albumId == null ->
                    credits.copy(albumId = id, albumName = run.s("text"))
                else -> credits
            }
        }
        return credits
    }

    /**
     * Who a release page is billed to, off its own header. An album or single
     * doesn't repeat the credit on every track — it says "Single • Artist"
     * once at the top and then lists bare titles, so every row read on its
     * own comes back as "Unknown artist". Only releases, never playlists: a
     * playlist's header names whoever put it together, which is not what its
     * tracks are by.
     */
    private fun pageCredit(root: JsonElement): Credits {
        val header = HEADER_RENDERERS.firstNotNullOfOrNull {
            collectRenderers(root, it).firstOrNull()
        } ?: return Credits()
        // The current header hangs the artist off a strapline above the
        // title; the older one packs it into the subtitle,
        // "Album • Artist • 2024". Split per line, not across them.
        val lines = HEADER_CREDIT_LINES.map { header.o(it).a("runs").orEmpty() }
        val parts = lines.flatMap { line ->
            line.joinToString("") { it.s("text").orEmpty() }.split(" • ").map(String::trim)
        }
        if (parts.none { it.lowercase() in RELEASE_WORDS }) return Credits()

        val credits = creditsOf(lines.flatten())
        if (credits.artistName?.isNotBlank() == true) return credits
        // An artist YouTube has no page for is named in the same line
        // without a link to follow, leaving the name as the only lead.
        val name = parts.firstOrNull {
            it.isNotBlank() && it.lowercase() !in TYPE_WORDS && !it.matches(TALLY) &&
                !it.matches(YEAR) && !it.matches(DURATION)
        }
        return credits.copy(artistName = name)
    }

    // ---- Home feed ----------------------------------------------------------

    /**
     * Shelves off a browse page (Home, Explore, charts, new releases all
     * arrive through `browse`). Upstream's `parseHome` verbatim.
     */
    fun parseHome(response: JsonObject): List<HomeShelf> {
        val sections = homeSectionContents(response)
        val fromColumn = sections.mapNotNull { section ->
            section.o("musicCarouselShelfRenderer")?.let(::carouselShelf)
                ?: section.o("musicShelfRenderer")?.let(::plainShelf)
        }
        if (fromColumn.isNotEmpty()) return fromColumn
        // Signed-in WEB_REMIX often serves twoColumnBrowseResultsRenderer;
        // walk the tree the same way continuations do.
        return parseHomeContinuation(response)
    }

    private fun homeSectionContents(response: JsonObject): List<JsonElement> {
        val contents = response.o("contents")
        contents.o("singleColumnBrowseResultsRenderer")
            .a("tabs")?.firstOrNull()
            .o("tabRenderer").o("content").o("sectionListRenderer").a("contents")
            ?.takeIf { it.isNotEmpty() }
            ?.let { return it }
        val two = contents.o("twoColumnBrowseResultsRenderer")
        sequenceOf(
            two.o("primaryContents").o("sectionListRenderer").a("contents"),
            two.o("secondaryContents").o("sectionListRenderer").a("contents"),
            two.a("tabs")?.firstOrNull()
                .o("tabRenderer").o("content").o("sectionListRenderer").a("contents"),
        ).firstOrNull { !it.isNullOrEmpty() }?.let { return it }
        return emptyList()
    }

    /**
     * More Home shelves off a continuation (or a two-column first page).
     * Walks carousel/plain shelves wherever they land.
     */
    fun parseHomeContinuation(root: JsonElement): List<HomeShelf> {
        val out = mutableListOf<HomeShelf>()
        fun walk(node: JsonElement) {
            when (node) {
                is JsonObject -> {
                    (node["musicCarouselShelfRenderer"] as? JsonObject)
                        ?.let(::carouselShelf)?.let(out::add)
                    (node["musicShelfRenderer"] as? JsonObject)
                        ?.let(::plainShelf)?.let(out::add)
                    node.values.forEach(::walk)
                }
                is JsonArray -> node.forEach(::walk)
                else -> Unit
            }
        }
        walk(root)
        return out
    }

    /** The token for the next page of a browse feed, null once exhausted. */
    fun continuationToken(root: JsonElement): String? {
        collectRenderers(root, "continuationItemRenderer").firstOrNull()
            .o("continuationEndpoint").o("continuationCommand").s("token")
            ?.let { return it }
        return collectRenderers(root, "nextContinuationData").firstOrNull().s("continuation")
    }

    private fun carouselShelf(carousel: JsonObject): HomeShelf? {
        val header = carousel.o("header").o("musicCarouselShelfBasicHeaderRenderer")
        val title = header.o("title").runs()
        val strapline = header.o("strapline").runs()
        // Whole shelves like "Video charts" carry nothing but video
        // compilations — each card would fail its own video check on the
        // way to a dead-end page, so the shelf is dropped outright.
        if (VIDEO_WORD.containsMatchIn(title)) return null
        val items = carousel.a("contents").orEmpty().mapNotNull { item ->
            parseTwoRowItem(item.o("musicTwoRowItemRenderer"))
                ?: parseResponsiveListItem(item.o("musicResponsiveListItemRenderer"))
                    ?.takeUnless { it.isVideo }
                    ?.let { song ->
                        ShelfItem(song.title, song.artist, song.thumbnailUrl, song.videoId, null)
                    }
                // A chart row with nothing to play — "Top artists" lists the
                // artist alone, no track — falls through parseResponsiveListItem
                // (it demands a videoId) and would drop the whole shelf.
                ?: parseArtistRow(item.o("musicResponsiveListItemRenderer"))
        }
        return if (items.isEmpty()) null else HomeShelf(title.ifBlank { "For you" }, items, strapline)
    }

    private fun plainShelf(shelf: JsonObject): HomeShelf? {
        val title = shelf.o("title").runs()
        if (VIDEO_WORD.containsMatchIn(title)) return null
        val items = shelf.a("contents").orEmpty().mapNotNull {
            parseResponsiveListItem(it.o("musicResponsiveListItemRenderer"))
        }.filterNot { it.isVideo }
            .map { ShelfItem(it.title, it.artist, it.thumbnailUrl, it.videoId, null) }
        return if (items.isEmpty()) null else HomeShelf(title.ifBlank { "For you" }, items)
    }

    /**
     * Cards on a library feed — saved playlists, albums, artists.
     * Grid view is `musicTwoRowItemRenderer`; list view is responsive rows.
     */
    fun parseLibraryItems(root: JsonElement): List<ShelfItem> {
        val out = LinkedHashMap<String, ShelfItem>()
        collectRenderers(root, "musicTwoRowItemRenderer").forEach { renderer ->
            val item = parseTwoRowItem(renderer) ?: return@forEach
            item.browseId?.let { id -> out.getOrPut(id) { item } }
        }
        collectRenderers(root, "musicResponsiveListItemRenderer").forEach { renderer ->
            val item = parseBrowseItem(renderer) ?: return@forEach
            out.getOrPut(item.browseId) {
                ShelfItem(item.title, item.subtitle, item.thumbnailUrl, null, item.browseId)
            }
        }
        return out.values.toList()
    }

    /**
     * A chart row with no playable track — "Top artists" lists the artist
     * alone. The browseId is read off the row's own navigationEndpoint (the
     * flex columns carry only the name and a tally).
     */
    private fun parseArtistRow(renderer: JsonObject?): ShelfItem? {
        if (renderer == null) return null
        val endpoint = renderer.o("navigationEndpoint").o("browseEndpoint")
        val pageType = endpoint.o("browseEndpointContextSupportedConfigs")
            .o("browseEndpointContextMusicConfig").s("pageType").orEmpty()
        if ("ARTIST" !in pageType) return null
        val browseId = endpoint.s("browseId") ?: return null

        val columns = renderer.a("flexColumns").orEmpty()
        val title = columns.getOrNull(0)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if (title.isBlank()) return null
        val subtitle = columns.getOrNull(1)
            .o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()

        val thumbnails = renderer.o("thumbnail").o("musicThumbnailRenderer")
            .o("thumbnail").a("thumbnails")
        return ShelfItem(
            title = title,
            subtitle = subtitle,
            thumbnailUrl = thumbnails.best(),
            videoId = null,
            browseId = browseId,
        )
    }

    /**
     * A shelf card: album/playlist/artist (browseId) or a playable track
     * (videoId). Upstream's `parseTwoRowItem` verbatim, including the MPED
     * non-music-audio unwrap and the video-compilation dead-end drops.
     */
    private fun parseTwoRowItem(renderer: JsonObject?): ShelfItem? {
        if (renderer == null) return null
        val title = renderer.o("title").runs()
        if (title.isBlank()) return null
        val endpoint = renderer.o("navigationEndpoint")
        val browseId = endpoint.o("browseEndpoint").s("browseId")
        // History/"Listen again" cards for tracks YouTube never catalogued
        // as a proper Song carry no watchEndpoint at all — just a browseId
        // to a "non-music audio track page" prefixed MPED<videoId>. That's
        // the actual video id, not a real browsable page.
        val videoId = endpoint.o("watchEndpoint").s("videoId")
            ?: browseId?.takeIf { it.startsWith("MPED") }?.removePrefix("MPED")
        val resolvedBrowseId = browseId?.takeUnless { it.startsWith("MPED") }
        val thumbnails = renderer.o("thumbnailRenderer").o("musicThumbnailRenderer")
            .o("thumbnail").a("thumbnails")
        val subtitle = renderer.o("subtitle").runs()
        // A card with no browse target is a playable track; widescreen art
        // on one means a music-video upload rather than the catalogue track.
        if (resolvedBrowseId == null && videoId != null && thumbnails.isNotSquare()) return null
        // An album/playlist billed as a video chart/compilation is a
        // dead-end. A plain track card is exempt: a song can legitimately
        // be titled "Video Games" without being a music-video upload.
        if (resolvedBrowseId != null &&
            (VIDEO_WORD.containsMatchIn(title) || VIDEO_WORD.containsMatchIn(subtitle))
        ) {
            return null
        }
        return ShelfItem(
            title = title,
            subtitle = subtitle,
            thumbnailUrl = thumbnails.best(),
            videoId = videoId,
            browseId = resolvedBrowseId,
        )
    }

    // ---- Detail pages -------------------------------------------------------

    /** An artist page: top songs, the release/carousel shelves below, and the
     *  header's own picture, name and stats. */
    data class ArtistPage(
        val songs: List<Song>,
        val sections: List<HomeShelf>,
        val thumbnailUrl: String?,
        val name: String?,
        val description: String?,
        val subscriberCountText: String?,
        val monthlyListenerCount: String?,
    )

    /**
     * Port of upstream's `parseArtistPage`. The first `musicShelfRenderer`
     * holds the top songs; carousels below become browsable sections. Rows
     * are credited to the artist by the page they sit on.
     */
    fun parseArtistPage(response: JsonObject): ArtistPage {
        val sections = response.o("contents")
            .o("singleColumnBrowseResultsRenderer").a("tabs")?.firstOrNull()
            .o("tabRenderer").o("content").o("sectionListRenderer").a("contents")
            .orEmpty()

        val songs = mutableListOf<Song>()
        val shelves = mutableListOf<HomeShelf>()
        val header = response["header"]
        // "Top songs" rows are billed by the page they sit on: the subtitle
        // beside them counts plays where a search row names the artist.
        val credit = Credits(artistName = artistName(header))

        sections.forEach { section ->
            section.o("musicShelfRenderer")?.let { shelf ->
                shelf.a("contents").orEmpty().forEach { row ->
                    parseResponsiveListItem(row.o("musicResponsiveListItemRenderer"), credit)
                        ?.let(songs::add)
                }
            }
            section.o("musicCarouselShelfRenderer")?.let { carousel ->
                val carouselHeader = carousel.o("header").o("musicCarouselShelfBasicHeaderRenderer")
                val title = carouselHeader.o("title").runs()
                if (VIDEO_WORD.containsMatchIn(title)) return@let
                val items = carousel.a("contents").orEmpty().mapNotNull {
                    parseTwoRowItem(it.o("musicTwoRowItemRenderer"))
                }.filter { it.browseId != null }
                if (title.isNotBlank() && items.isNotEmpty()) {
                    shelves += HomeShelf(title, items)
                }
            }
        }
        return ArtistPage(
            songs = songs,
            sections = shelves,
            thumbnailUrl = artistThumbnail(header),
            name = credit.artistName,
            description = parseDescription(response),
            subscriberCountText = subscriberCount(header),
            monthlyListenerCount = monthlyListeners(header),
        )
    }

    /**
     * "1.2M subscribers" off the artist header's subscribe button — YouTube
     * ships two shapes of it, and the button carries the count under one of
     * three different keys across those shapes.
     */
    private fun subscriberCount(header: JsonElement?): String? {
        val immersive = header.o("musicImmersiveHeaderRenderer") ?: return null
        val button2 = immersive.o("subscriptionButton2").o("subscribeButtonRenderer")
        val button1 = immersive.o("subscriptionButton").o("subscribeButtonRenderer")
        return button2.o("subscriberCountWithSubscribeText").firstRunText()
            ?: button1.o("longSubscriberCountText").firstRunText()
            ?: button1.o("shortSubscriberCountText").firstRunText()
    }

    /** "3.4M monthly listeners", off the same header as [subscriberCount]. */
    private fun monthlyListeners(header: JsonElement?): String? =
        header.o("musicImmersiveHeaderRenderer").o("monthlyListenerCount").firstRunText()

    /** The name the page bills itself under. */
    private fun artistName(header: JsonElement?): String? {
        val renderer = header.o("musicImmersiveHeaderRenderer")
            ?: header.o("musicVisualHeaderRenderer")
            ?: return null
        return renderer.o("title").runs().takeIf { it.isNotBlank() }
    }

    /**
     * The artist's own picture, off whichever header shape came back — the
     * immersive header serves it as `thumbnail`, the visual header as
     * `foregroundThumbnail` over a banner.
     */
    private fun artistThumbnail(header: JsonElement?): String? {
        if (header == null) return null
        val immersive = header.o("musicImmersiveHeaderRenderer")
        val visual = header.o("musicVisualHeaderRenderer")
        val renderer = (
            immersive.o("thumbnail")
                ?: visual.o("foregroundThumbnail")
                ?: visual.o("thumbnail")
            ).o("musicThumbnailRenderer")
            // Header shapes drift; fall back to the first image anywhere
            // under the header rather than to the caller's album art.
            ?: collectRenderers(header, "musicThumbnailRenderer").firstOrNull()
        return renderer.o("thumbnail").a("thumbnails").best()
    }

    /**
     * Walks the whole response collecting any `musicResponsiveListItemRenderer`
     * that carries a videoId. Layout-agnostic, so it survives the differences
     * between playlist and album pages.
     */
    fun collectSongsDeep(root: JsonElement): List<Song> {
        val out = LinkedHashMap<String, Song>()
        // A release's own rows are credited by its header, not one by one.
        val pageCredit = pageCredit(root)
        fun walk(node: JsonElement) {
            when (node) {
                is JsonObject -> {
                    node["musicResponsiveListItemRenderer"]?.let { renderer ->
                        parseResponsiveListItem(renderer as? JsonObject, pageCredit)
                            ?.let { out[it.videoId] = it }
                    }
                    node.values.forEach(::walk)
                }
                is JsonArray -> node.forEach(::walk)
                else -> Unit
            }
        }
        walk(root)
        return out.values.toList()
    }

    /** A playlist page's own tracks, plus suggested rows and the token for the rest. */
    data class PlaylistShelfPage(
        val songs: List<Song>,
        val continuation: String?,
        val suggested: List<Song> = emptyList(),
    )

    /**
     * A playlist page's own track list, scoped rather than walked: only a row
     * carrying a `playlistSetVideoId` inside `playlistItemData` is actually
     * in the playlist — the suggestion rows YouTube offers alongside are
     * structurally identical otherwise. Returns null off a page with nothing
     * playlist-shaped in scope (an album), so callers fall back to the
     * generic walk.
     */
    fun parsePlaylistShelf(root: JsonElement): PlaylistShelfPage? {
        val scope: JsonElement = root.o("continuationContents")
            ?: root.o("contents").o("twoColumnBrowseResultsRenderer").o("secondaryContents")
            ?: return null
        val looksLikePlaylist = collectRenderers(scope, "musicPlaylistShelfRenderer").isNotEmpty() ||
            scope.o("musicPlaylistShelfContinuation") != null
        if (!looksLikePlaylist) return null

        val pageCredit = pageCredit(root)
        val parsed = collectRenderers(scope, "musicResponsiveListItemRenderer")
            .mapNotNull { parseResponsiveListItem(it, pageCredit) }
            .distinctBy { it.videoId }
        val songs = parsed.filter { it.setVideoId != null }
        val suggested = parsed.filter { it.setVideoId == null }
        val token = collectRenderers(scope, "continuationItemRenderer").firstOrNull()
            .o("continuationEndpoint").o("continuationCommand").s("token")
            ?: collectRenderers(scope, "nextContinuationData").firstOrNull().s("continuation")
        return PlaylistShelfPage(songs, token, suggested)
    }

    /** How an album or playlist page bills itself, off its own header. */
    data class BrowseHeader(
        val title: String,
        /** The line under it — "Album • Artist • 2024", or a playlist's blurb. */
        val subtitle: String,
        val thumbnailUrl: String?,
    )

    /** The title/credit/cover a release or playlist page calls itself by. */
    fun parseBrowseHeader(root: JsonElement): BrowseHeader? {
        val header = HEADER_RENDERERS.firstNotNullOfOrNull {
            collectRenderers(root, it).firstOrNull()
        } ?: return null
        val title = header.o("title").runs()
        if (title.isBlank()) return null
        val subtitle = header.o("straplineTextOne").runs()
            .ifBlank { header.o("subtitle").runs() }
        return BrowseHeader(
            title = title,
            subtitle = subtitle,
            thumbnailUrl = collectRenderers(header, "musicThumbnailRenderer").firstOrNull()
                .o("thumbnail").a("thumbnails").best(),
        )
    }

    /**
     * The editorial blurb YouTube Music writes for a release or an artist —
     * "About the album" / "About the artist". Arrives as its own shelf
     * (`musicDescriptionShelfRenderer`) on a current-layout page, but also
     * turns up directly on the header itself on some responses.
     */
    fun parseDescription(root: JsonElement): String? {
        val shelf = collectRenderers(root, "musicDescriptionShelfRenderer")
            .firstOrNull()?.o("description").runs()
        if (shelf.isNotBlank()) return shelf
        return (HEADER_RENDERERS + "musicImmersiveHeaderRenderer")
            .firstNotNullOfOrNull { name ->
                collectRenderers(root, name).firstOrNull()
                    ?.o("description").runs().takeIf { it.isNotBlank() }
            }
    }

    // ---- Watch queue (AutoPlay radio) ---------------------------------------

    /** Tracks of a watch queue (`next` response) — the AutoPlay radio mix. */
    fun parseWatchQueue(root: JsonElement): List<Song> {
        val out = LinkedHashMap<String, Song>()
        collectRenderers(root, "playlistPanelVideoRenderer").forEach { renderer ->
            val videoId = renderer.s("videoId") ?: return@forEach
            val title = renderer.o("title").runs()
            if (title.isBlank()) return@forEach
            // The byline packs artist, views and likes into one run list;
            // only the leading runs before the first bullet are the credit.
            val bylineRuns = renderer.o("longBylineText").a("runs").orEmpty()
            val byline = bylineRuns.map { it.s("text").orEmpty() }
            val artist = byline.takeWhile { !it.contains("•") }.joinToString("").trim()
            val credits = creditsOf(bylineRuns)
            out[videoId] = Song(
                videoId = videoId,
                title = title,
                artist = artist.ifBlank { "Unknown artist" },
                thumbnailUrl = renderer.o("thumbnail").a("thumbnails").best(),
                durationText = renderer.o("lengthText").runs().takeIf { it.isNotBlank() },
                artistId = credits.artistId,
                albumId = credits.albumId,
                albumName = credits.albumName,
                // A catalogue track is credited "Artist • Album • Year"; the
                // matching music video is "Artist • 417M views • 2.4M likes".
                isVideo = byline.any { it.contains("views", ignoreCase = true) },
            )
        }
        return out.values.toList()
    }

    // ---- Account ------------------------------------------------------------

    /**
     * The account header buried in the `account_menu` popup. Not every client
     * gets an `email` back — some return only the @handle — so whichever is
     * present is used as the secondary line.
     */
    fun parseAccount(response: JsonElement): Account? {
        val header = collectRenderers(response, "activeAccountHeaderRenderer").firstOrNull()
            ?: return null
        val name = header.o("accountName").runs()
        if (name.isBlank()) return null
        val email = header.o("email").runs()
            .ifBlank { header.o("email").s("simpleText").orEmpty() }
            .ifBlank { header.o("channelHandle").runs() }
        return Account(
            name = name,
            email = email,
            photoUrl = header.o("accountPhoto").a("thumbnails").best(),
        )
    }

    fun parseSongMenu(root: JsonElement, videoId: String): SongMenu? {
        val row = collectRenderers(root, "playlistPanelVideoRenderer")
            .firstOrNull { it.s("videoId") == videoId }
            ?: return null
        val likeStatus = when (
            collectRenderers(row, "likeButtonRenderer").firstOrNull().s("likeStatus")
        ) {
            "LIKE" -> LikeStatus.LIKE
            "DISLIKE" -> LikeStatus.DISLIKE
            "INDIFFERENT" -> LikeStatus.INDIFFERENT
            else -> null
        }
        val toggle = collectRenderers(row, "toggleMenuServiceItemRenderer")
            .firstOrNull { it.feedbackToken("defaultServiceEndpoint") != null && it.isLibraryToggle }
        val defaultAdds = toggle.o("defaultIcon").s("iconType") == "LIBRARY_ADD"
        val defaultToken = toggle.feedbackToken("defaultServiceEndpoint")
        val toggledToken = toggle.feedbackToken("toggledServiceEndpoint")
        return SongMenu(
            likeStatus = likeStatus?.name,
            inLibrary = toggle != null && !defaultAdds,
            addToLibraryToken = if (defaultAdds) defaultToken else toggledToken,
            removeFromLibraryToken = if (defaultAdds) toggledToken else defaultToken,
        )
    }

    private fun JsonElement?.feedbackToken(endpoint: String): String? =
        this.o(endpoint).o("feedbackEndpoint").s("feedbackToken")

    private val JsonElement?.isLibraryToggle: Boolean
        get() = LIBRARY_ICONS.any {
            o("defaultIcon").s("iconType") == it || o("toggledIcon").s("iconType") == it
        }

    private val LIBRARY_ICONS = setOf("LIBRARY_ADD", "LIBRARY_REMOVE", "LIBRARY_SAVED")

    fun parseLibraryState(root: JsonElement): LibraryState? {
        val buttons = collectRenderers(root, "musicResponsiveHeaderRenderer")
            .firstOrNull()
            .a("buttons")
            .orEmpty()
        val save = buttons.firstNotNullOfOrNull {
            it.o("toggleButtonRenderer")?.takeIf { b -> b.isSaveToggle }
        } ?: return null
        if (save.s("isDisabled") == "true") return null
        val play = buttons.firstNotNullOfOrNull {
            it.o("musicPlayButtonRenderer").o("playNavigationEndpoint")
        }
        return LibraryState(
            playlistId = play.o("watchPlaylistEndpoint").s("playlistId")
                ?: play.o("watchEndpoint").s("playlistId")
                ?: return null,
            saved = save.s("isToggled") == "true",
        )
    }

    private val JsonElement?.isSaveToggle: Boolean
        get() = o("defaultIcon").s("iconType") == "BOOKMARK_BORDER" ||
            o("toggledIcon").s("iconType") == "BOOKMARK"

    fun parsePlaylistOwned(root: JsonElement): Boolean? {
        if (collectRenderers(root, "musicEditablePlaylistDetailHeaderRenderer").isNotEmpty()) {
            return true
        }
        val header = collectRenderers(root, "musicResponsiveHeaderRenderer").firstOrNull()
            ?: return null
        if (collectRenderers(header, "menuNavigationItemRenderer")
                .any { it.o("icon").s("iconType") in OWNER_ICONS }
        ) {
            return true
        }
        return header.a("buttons").orEmpty().none { it.o("toggleButtonRenderer").isSaveToggle }
    }

    private val OWNER_ICONS = setOf("DELETE", "EDIT")

    fun parseUserPlaylists(root: JsonElement): List<UserPlaylist> =
        parseLibraryItems(root).mapNotNull { item ->
            val browseId = item.browseId ?: return@mapNotNull null
            if (!browseId.startsWith("VL")) return@mapNotNull null
            if (NOT_EDITABLE.any { browseId.startsWith("VL$it") }) return@mapNotNull null
            UserPlaylist(
                playlistId = browseId.removePrefix("VL"),
                title = item.title,
                subtitle = item.subtitle,
                thumbnailUrl = item.thumbnailUrl,
            )
        }

    private val NOT_EDITABLE = listOf("LM", "SE", "RD", "OLAK", "MPRE")

    // ---- Filter scope -------------------------------------------------------

    /** Serialized params for a search scope, from the shared model's table. */
    fun paramsFor(scope: String): String? = when (scope.lowercase()) {
        "albums" -> SearchFilter.ALBUMS.params
        "artists" -> SearchFilter.ARTISTS.params
        "playlists" -> SearchFilter.PLAYLISTS.params
        else -> SearchFilter.SONGS.params
    }

    private val DURATION = Regex("""\d+:\d{2}""")
    private val TALLY = Regex(
        """[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|""" +
            """hours?|minutes?|seconds?)\b.*""",
        RegexOption.IGNORE_CASE,
    )
    private val TYPE_WORDS = setOf(
        "song", "video", "album", "single", "ep", "artist",
        "playlist", "podcast", "episode",
    )
    private val VIDEO_WORD = Regex("""\bvideos?\b""", RegexOption.IGNORE_CASE)
    private val YEAR = Regex("""\d{4}""")
    private val RELEASE_WORDS = setOf("album", "single", "ep")
    private val HEADER_RENDERERS = listOf(
        "musicResponsiveHeaderRenderer",
        "musicDetailHeaderRenderer",
    )

    /** Header lines that name the artist, in either header shape. */
    private val HEADER_CREDIT_LINES = listOf("straplineTextOne", "subtitle")
}

// ---- Tiny JSON navigation helpers (null-safe, never throw) ------------------

internal fun JsonElement?.o(key: String): JsonObject? =
    (this as? JsonObject)?.get(key) as? JsonObject

internal fun JsonElement?.a(key: String): JsonArray? =
    (this as? JsonObject)?.get(key) as? JsonArray

internal fun JsonElement?.s(key: String): String? =
    ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.contentOrNull

internal fun JsonElement?.runs(): String =
    this.a("runs")?.joinToString("") { it.s("text").orEmpty() }.orEmpty()

/** The first run's text, or null when there are no runs at all. */
internal fun JsonElement?.firstRunText(): String? =
    this.a("runs")?.firstOrNull().s("text")

/** Last thumbnail is the largest, taken exactly as offered — sizing happens
 *  where the image is drawn ([com.music.bitchord.data.model.artworkAt]). */
internal fun JsonArray?.best(): String? = this?.lastOrNull().s("url")

internal fun JsonArray?.isNotSquare(): Boolean {
    val last = this?.lastOrNull()
    val width = last.s("width")?.toDoubleOrNull() ?: return false
    val height = last.s("height")?.toDoubleOrNull() ?: return false
    if (width <= 0 || height <= 0) return false
    return width / height !in 0.85..1.15
}

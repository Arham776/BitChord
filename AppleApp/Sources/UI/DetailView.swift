import SwiftUI
import BitChordShared

/// Detail page for an album / artist / playlist browseId.
///
/// Port of upstream `DetailScreen.kt`:
/// Three-layer architecture:
/// 1. Page background: Artwork wash tint + edge-to-edge hero sleeve/photo cropped across top.
/// 2. MergeBand: Glass blur across the artwork foot, dissolving the cover into the wash.
/// 3. Scrollable content: Centered title, accent credit, metadata, and a clean action row
///    of circular controls (Save/Subscribe, Shuffle, Play pill, Search, More), followed
///    by the search filter, track list, and playtime summary.
struct DetailView: View {
    let browseId: String
    let initialTitle: String
    @Environment(PlaybackController.self) private var controller
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var page: DetailPageModel?
    @State private var error: String?
    @State private var loading = true
    @State private var headerArt: Data?
    @State private var filter = ""
    /// Owned-playlist reordering. A real mode with a control, not a forced
    /// `.active` — see `NowPlayingView.UpNextPane`.
    ///
    /// iOS-only, like `EditMode` itself. On macOS the list is reordered by
    /// click-to-move instead, which is the platform's own idiom.
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    @State private var saved = false
    @State private var saving = false
    @State private var continuation: String?
    @State private var pageRequestID = UUID()
    @State private var suggested: [DetailPageModel.SongPayload] = []
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(ToastCenter.self) private var toast
    @State private var subscriptionOverride: Bool?
    @State private var subscribing = false
    @State private var renameTitle = ""
    @State private var renamePresented = false
    @State private var privacy = "PRIVATE"
    @State private var privacyPresented = false
    @State private var canvasURL: URL?
    @State private var canvasFallbackURL: URL?
    @State private var pinned = false
    @State private var scrolledPastHeader = false
    /// Narrows the track list in place, like upstream's search circle in the
    /// release header. Off until tapped, so a long list reads as a list first.
    @State private var searching = false

    private var useDesktopHeader: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if loading {
                ScrollView { FeedSkeleton() }
            } else if let error {
                EmptyStateView(icon: Image(.bchMusicNote), title: "Couldn't load", subtitle: error, buttonTitle: "Retry") {
                    Task { await load() }
                }
            } else if let page {
                loadedPage(page)
            }
        }
        .refreshable { await load(force: true) }
        .navigationTitle(scrolledPastHeader ? (page?.title.isEmpty == false ? page!.title : initialTitle) : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                detailActionsMenu(page: page)
                TopBarAccountButton()
            }
        }
        #endif
        .alert("Rename Playlist", isPresented: $renamePresented) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                Task {
                    _ = await LibraryActions.renamePlaylist(playlistId: browseId, title: renameTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Playlist privacy", isPresented: $privacyPresented, titleVisibility: .visible) {
            Button("Private") { Task { await setPrivacy("PRIVATE") } }
            Button("Unlisted") { Task { await setPrivacy("UNLISTED") } }
            Button("Public") { Task { await setPrivacy("PUBLIC") } }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: auth.sessionEpoch) {
            page = nil; continuation = nil; headerArt = nil
            saving = false; subscribing = false; subscriptionOverride = nil
            pinned = PlaylistPinning.pinnedIds().contains(browseId)
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageCacheUpdated)) { note in
            guard let name = note.object as? String, name == "detail:browse:\(browseId)" || name == "detail:browseArtist:\(browseId)" else { return }
            Task { await load() }
        }
    }

    private func loadedPage(_ page: DetailPageModel) -> some View {
        let tint = ArtworkPalette.pageTint(from: headerArt, seed: page.title.hashValue, dark: colorScheme == .dark)
        let isArtist = kind(of: page) == .artist

        return GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // Upstream's ratio math: ARTIST_PHOTO_RATIO = 0.95, SLEEVE_RATIO = 0.92
            // Capped against window height (0.55) so the tracks aren't buried
            let rawRatio: CGFloat = isArtist ? 0.95 : 0.92
            let artHeight = min(width / rawRatio, height * 0.55)

            ScrollView {
                VStack(spacing: 0) {
                    if useDesktopHeader && !isArtist {
                        desktopHeaderView(page, tint: tint, isArtist: isArtist)
                    } else {
                        headerView(page, tint: tint, isArtist: isArtist, artHeight: artHeight)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if CacheStatus.shared.saved.contains("detail:browse:\(browseId)") || CacheStatus.shared.saved.contains("detail:browseArtist:\(browseId)") {
                            SavedContentNotice(message: CacheStatus.shared.failures["detail:browse:\(browseId)"])
                                .padding(.vertical, 8)
                        }
                        if !page.songs.isEmpty {
                            if searching {
                                searchField(tint: tint)
                            }
                            trackList(page)
                                .padding(.horizontal, 16)

                            if !isArtist {
                                Text(playtimeSummary(page.songs))
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                            }
                        } else if page.sections.isEmpty {
                            EmptyStateView(icon: Image(.bchMusicNote), title: "No tracks", subtitle: "This page has no playable tracks.", buttonTitle: nil, action: nil)
                        }

                        if !suggested.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Suggested")
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.top, 20)
                                ForEach(suggested, id: \.videoId) { song in
                                    SongRow(
                                        entry: toEntry(song, fallbackArt: fallbackArt(page)),
                                        play: { controller.playRadio(toEntry(song, fallbackArt: fallbackArt(page))) },
                                        playNext: { controller.playNext(toEntry(song, fallbackArt: fallbackArt(page))) },
                                        addToQueue: { controller.addToQueue(toEntry(song, fallbackArt: fallbackArt(page))) }
                                    )
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        if let desc = page.description, !desc.isEmpty, kind(of: page) != .playlist {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(isArtist ? "About the artist" : "About the album")
                                    .font(.headline)
                                Text(desc)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 28)
                        }

                        ForEach(page.sections) { shelf in
                            ShelfCarousel(shelf: shelf)
                                .padding(.horizontal, 28)
                                .padding(.top, 28)
                        }
                    }
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 36)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y > (artHeight - 50)
            } action: { _, isScrolled in
                if scrolledPastHeader != isScrolled {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrolledPastHeader = isScrolled
                    }
                }
            }
            #if os(iOS)
            .ignoresSafeArea(edges: .top)
            #endif
            .background {
                pageWash(tint: tint)
            }
        }
        .task(id: page.thumbnailUrl) {
            headerArt = await loadHeaderArt(page.thumbnailUrl)
            await loadCanvas(page)
        }
    }

    @ViewBuilder
    private func detailActionsMenu(page: DetailPageModel?) -> some View {
        if let page {
            Menu {
                if let urlString = page.url, let url = URL(string: urlString) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                if !pinned {
                    Button {
                        if PlaylistPinning.toggle(browseId: browseId) {
                            pinned = true
                        } else {
                            appModel.pinLimitAlert = true
                        }
                    } label: {
                        Label("Pin to Library", systemImage: "pin")
                    }
                } else {
                    Button {
                        if PlaylistPinning.toggle(browseId: browseId) {
                            pinned = false
                        }
                    } label: {
                        Label("Unpin from Library", systemImage: "pin.slash")
                    }
                }
                if kind(of: page) == .playlist, page.playlistOwned == true {
                    Button {
                        renameTitle = page.title
                        renamePresented = true
                    } label: {
                        Label("Rename Playlist", systemImage: "pencil")
                    }
                    Button {
                        privacyPresented = true
                    } label: {
                        Label("Playlist Privacy…", systemImage: "lock")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
            }
            .buttonStyle(ProfileCircleButtonStyle())
            .accessibilityLabel("More Options")
        }
    }

    /// Apple Music split header for iPad and Mac: artwork card on the left,
    /// title, credits, metadata, and full action row on the right.
    private func desktopHeaderView(
        _ page: DetailPageModel,
        tint: ArtworkPalette.PageTint,
        isArtist: Bool
    ) -> some View {
        let lines = headerLines(page)
        let credit = lines.credit.isEmpty ? (page.songs.first?.artist ?? "") : lines.credit
        let artistId = page.songs.first?.artistId

        return HStack(alignment: .bottom, spacing: 32) {
            ZStack {
                ArtworkView(url: page.thumbnailUrl, data: headerArt, side: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
                if let canvasURL {
                    CanvasPlayer(url: canvasURL, fallbackURL: canvasFallbackURL, isPlaying: true)
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(isArtist ? "ARTIST" : (kind(of: page) == .playlist ? "PLAYLIST" : "ALBUM"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)

                Text(page.title.isEmpty ? initialTitle : page.title)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)

                if !credit.isEmpty {
                    if let artistId, kind(of: page) != .artist {
                        NavigationLink(destination: DetailView(browseId: artistId, initialTitle: credit)) {
                            Text(credit)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(tint.accent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(credit)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(tint.accent)
                            .lineLimit(1)
                    }
                }

                if !lines.meta.isEmpty {
                    Text(lines.meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isArtist, page.subscriberCountText != nil || page.monthlyListenerCount != nil {
                    artistStatsRow(page: page, tint: tint)
                }

                if !page.songs.isEmpty {
                    actionRow(page, tint: tint, isArtist: isArtist)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Header zone: hero artwork with gradient fade, MergeBand glass, and pinned title/credit/actions.
    private func headerView(
        _ page: DetailPageModel,
        tint: ArtworkPalette.PageTint,
        isArtist: Bool,
        artHeight: CGFloat
    ) -> some View {
        let lines = headerLines(page)
        let credit = lines.credit.isEmpty ? (page.songs.first?.artist ?? "") : lines.credit
        let artistId = page.songs.first?.artistId

        return ZStack(alignment: .bottom) {
            // Hero artwork at the top
            ZStack(alignment: .top) {
                heroImage(url: page.thumbnailUrl, data: headerArt, height: artHeight)

                if let canvasURL {
                    CanvasPlayer(url: canvasURL, fallbackURL: canvasFallbackURL, isPlaying: true)
                        .frame(height: artHeight)
                        .clipped()
                }

                // Upstream's gradient: settling the foot of the picture onto the wash colour
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: tint.wash.opacity(0.92), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: artHeight)
                .allowsHitTesting(false)
            }
            .frame(height: artHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                mergeBand(tint: tint)
                    .frame(height: 80)
                    .offset(y: 20)
                    .allowsHitTesting(false)
            }

            // Foreground Text and Actions pinned to the bottom of the header
            VStack(spacing: 6) {
                Text(page.title.isEmpty ? initialTitle : page.title)
                    .font(isArtist ? .system(size: 32, weight: .bold) : .title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 24)

                if !credit.isEmpty {
                    if let artistId, kind(of: page) != .artist {
                        NavigationLink(destination: DetailView(browseId: artistId, initialTitle: credit)) {
                            Text(credit)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(tint.accent)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    } else {
                        Text(credit)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(tint.accent)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .padding(.horizontal, 24)
                    }
                }

                if !lines.meta.isEmpty {
                    Text(lines.meta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }

                if isArtist, page.subscriberCountText != nil || page.monthlyListenerCount != nil {
                    artistStatsRow(page: page, tint: tint)
                        .padding(.top, 4)
                }

                if !page.songs.isEmpty {
                    actionRow(page, tint: tint, isArtist: isArtist)
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: 860)
        }
        .frame(height: artHeight + 44) // Upstream's HEADER_DROP = 44dp
    }

    /// Single horizontal row of circular action buttons, matching upstream's ReleaseHeader and ActionRow.
    private func actionRow(
        _ page: DetailPageModel,
        tint: ArtworkPalette.PageTint,
        isArtist: Bool
    ) -> some View {
        HStack(spacing: 12) {
            if isArtist {
                if auth.signedIn, let subscription = page.subscription {
                    let isSub = subscriptionOverride ?? subscription.subscribed
                    CircleIconButton(
                        icon: Image(systemName: isSub ? "checkmark" : "plus"),
                        label: isSub ? "Unsubscribe" : "Subscribe",
                        active: isSub,
                        activeColor: tint.accent,
                        disabled: subscribing
                    ) {
                        Task { await toggleSubscription(subscription, artistName: page.title) }
                    }
                }

                PlayPill(iconOnly: false) {
                    controller.play(page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }, at: 0)
                }

                CircleIconButton(
                    icon: Image(.bchShuffle),
                    label: "Shuffle"
                ) {
                    var shuffled = page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }
                    shuffled.shuffle()
                    controller.play(shuffled, at: 0)
                }
            } else {
                if auth.signedIn, page.libraryPlaylistId != nil {
                    CircleIconButton(
                        icon: Image(systemName: saved ? "checkmark" : "plus"),
                        label: saved ? "Remove from Library" : "Add to Library",
                        active: saved,
                        activeColor: tint.accent,
                        disabled: saving
                    ) {
                        Task { await toggleSave(page) }
                    }
                }

                CircleIconButton(
                    icon: Image(.bchShuffle),
                    label: "Shuffle"
                ) {
                    var shuffled = page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }
                    shuffled.shuffle()
                    controller.play(shuffled, at: 0)
                }

                PlayPill(iconOnly: true) {
                    controller.play(page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }, at: 0)
                }

                CircleIconButton(
                    icon: Image(systemName: searching ? "xmark" : "magnifyingglass"),
                    label: searching ? "Close search" : "Search this list",
                    active: searching,
                    activeColor: tint.accent
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if searching { filter = "" }
                        searching.toggle()
                    }
                }

                CircleMenuButton(label: "More actions") {
                    Button(pinned ? "Unpin" : "Pin") {
                        if PlaylistPinning.toggle(browseId: browseId) {
                            pinned.toggle()
                        } else {
                            appModel.pinLimitAlert = true
                        }
                    }
                    Button("Download") {
                        Task {
                            switch await DownloadStore.shared.downloadCollection(browseId: browseId) {
                            case .started:
                                toast.show("Downloading \(page.title)")
                            case .blockedByWifiOnly:
                                toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                            case .alreadyExists:
                                toast.show("This collection is already downloading or downloaded", kind: .info)
                            case .ignoredLocalTrack:
                                break
                            }
                        }
                    }
                    if kind(of: page) == .playlist, page.playlistOwned == true {
                        Button("Rename Playlist…") {
                            renameTitle = page.title
                            renamePresented = true
                        }
                        Button("Privacy: \(privacy.capitalized)") {
                            privacyPresented = true
                        }
                        Button("Remove Duplicates") {
                            Task { await removeDuplicates(page) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Sleek inline filter bar displayed when searching is toggled on.
    private func searchField(tint: ArtworkPalette.PageTint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            TextField("Search this list", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func artistStatsRow(page: DetailPageModel, tint: ArtworkPalette.PageTint) -> some View {
        HStack(spacing: 8) {
            if let sub = page.subscriberCountText, !sub.isEmpty {
                let text = sub.components(separatedBy: " ").first ?? sub
                statChip(icon: "person.2.fill", text: "\(text) subscribers")
            }
            if let monthly = page.monthlyListenerCount, !monthly.isEmpty {
                let text = monthly.components(separatedBy: " ").first ?? monthly
                statChip(icon: "waveform", text: "\(text) monthly listeners")
            }
        }
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func heroImage(url: String?, data: Data?, height: CGFloat) -> some View {
        Group {
            if let data, let image = PlatformImage(data: data) {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else if let url, let image = ArtworkCache.shared.get(url) {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else if let url, let imageURL = URL(string: SharedArtwork.sized(url, 720) ?? url) {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                }
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(height: height)
        .clipped()
    }

    /// One pane of glass across the artwork/page join, masked to arrive from
    /// nothing and leave to nothing so neither of its own edges shows.
    /// Skipped with Reduce Motion's blur sibling (`reduce_dynamic_blur`), like
    /// upstream, leaving the wash gradient to settle the join on its own.
    private func mergeBand(tint: ArtworkPalette.PageTint) -> some View {
        Group {
            if PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false) {
                EmptyView()
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }

    private func pageWash(tint: ArtworkPalette.PageTint) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.background)
            LinearGradient(
                colors: [tint.wash, tint.wash.opacity(0.35), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 520)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Upstream's `playtimeSummary`: "16 songs, 48 minutes"
    private func playtimeSummary(_ songs: [DetailPageModel.SongPayload]) -> String {
        let count = "\(songs.count) \(songs.count == 1 ? "song" : "songs")"
        let totalSeconds = songs.reduce(0) { sum, s in
            sum + durationToSeconds(s.durationText)
        }
        let minutes = totalSeconds / 60
        guard minutes > 0 else { return count }
        if minutes < 60 {
            return "\(count), \(minutes) minutes"
        } else {
            let hours = minutes / 60
            let rest = minutes % 60
            let hourLabel = "\(hours) \(hours == 1 ? "hour" : "hours")"
            return rest == 0 ? "\(count), \(hourLabel)" : "\(count), \(hourLabel) \(rest) minutes"
        }
    }

    private func durationToSeconds(_ text: String?) -> Int {
        guard let text else { return 0 }
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    private func trackList(_ page: DetailPageModel) -> some View {
        let fallback = page.thumbnailUrl
        let songs = page.songs.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter)
        }
        let owned = page.playlistOwned == true && filter.isEmpty
        return Group {
            if owned {
                List {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        SongRow(
                            entry: toEntry(song, fallbackArt: fallback),
                            play: { controller.play(page.songs.map { toEntry($0, fallbackArt: fallback) }, at: page.songs.firstIndex(where: { $0.videoId == song.videoId }) ?? index) },
                            playNext: { controller.playNext(toEntry(song, fallbackArt: fallback)) },
                            addToQueue: { controller.addToQueue(toEntry(song, fallbackArt: fallback)) },
                            playlistBrowseId: browseId,
                            playlistOwned: true
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .onAppear {
                            if song.videoId == songs.last?.videoId {
                                Task { await loadMore() }
                            }
                        }
                    }
                    .onMove { source, dest in
                        Task { await reorder(from: source, to: dest) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: CGFloat(max(songs.count, 1)) * 58)
                #if os(iOS)
                // Owned playlists are reorderable, so they get a real edit mode
                // with an explicit Reorder control rather than being permanently
                // in one — see the note in `NowPlayingView.UpNextPane`.
                .environment(\.editMode, $editMode)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if songs.count > 1 {
                        HStack {
                            Spacer()
                            Button(editMode == .active ? "Done" : "Reorder") {
                                withAnimation {
                                    editMode = editMode == .active ? .inactive : .active
                                }
                            }
                            .font(.callout)
                            .padding(.trailing, 16)
                            .padding(.bottom, 4)
                        }
                    }
                }
                #endif
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.videoId) { index, song in
                        SongRow(
                            entry: toEntry(song, fallbackArt: fallback),
                            play: { controller.play(page.songs.map { toEntry($0, fallbackArt: fallback) }, at: page.songs.firstIndex(where: { $0.videoId == song.videoId }) ?? index) },
                            playNext: { controller.playNext(toEntry(song, fallbackArt: fallback)) },
                            addToQueue: { controller.addToQueue(toEntry(song, fallbackArt: fallback)) },
                            playlistBrowseId: browseId,
                            playlistOwned: page.playlistOwned == true
                        )
                        .onAppear {
                            if song.videoId == songs.last?.videoId {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toEntry(_ s: DetailPageModel.SongPayload, fallbackArt: String? = nil) -> QueueEntry {
        s.asEntry(fallbackArt: fallbackArt)
    }

    private func fallbackArt(_ page: DetailPageModel) -> String? {
        page.thumbnailUrl
    }

    private enum Kind { case album, artist, playlist, other }

    private func kind(of page: DetailPageModel) -> Kind {
        switch page.type?.uppercased() {
        case "ALBUM": return .album
        case "ARTIST": return .artist
        case "PLAYLIST": return .playlist
        default:
            if browseId.hasPrefix("UC") { return .artist }
            if browseId.hasPrefix("MPREb") || browseId.hasPrefix("OLAK") { return .album }
            if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { return .playlist }
            return .other
        }
    }

    /// Splits "Album • Artist • 2023" into the credit line and the metadata
    /// line Music shows under the title. Port of upstream `headerLines`.
    private func headerLines(_ page: DetailPageModel) -> (credit: String, meta: String) {
        let parts = page.subtitle
            .split(whereSeparator: { $0 == "•" || $0 == "·" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let kinds = Set(["album", "single", "ep", "playlist", "artist", "podcast", "episode", "song", "video"])
        let year = parts.last { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        let kindWord = parts.first { kinds.contains($0.lowercased()) }
        let credit = parts.filter { $0 != year && $0 != kindWord }.joined(separator: ", ")
        let kindLabel = kindWord ?? {
            switch kind(of: page) {
            case .album: return "Album"
            case .playlist: return "Playlist"
            case .artist: return "Artist"
            case .other: return nil
            }
        }()
        let count = page.songs.count
        let countText = count > 0 ? "\(count) \(count == 1 ? "song" : "songs")" : nil
        let meta = [kindLabel, year, countText].compactMap { $0 }.joined(separator: "  ·  ")
        return (credit, meta)
    }

    private func loadHeaderArt(_ url: String?) async -> Data? {
        guard let url else { return nil }
        let sized = SharedArtwork.sized(url, 720) ?? url
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: sized)
        return await ArtworkRequests.shared.data(url: sized, headers: headers)
    }

    private func load(force: Bool = false) async {
        let request = UUID(); pageRequestID = request
        let generation = PageSession.generation()
        loading = page == nil
        error = nil
        subscriptionOverride = nil
        do {
            if browseId.hasPrefix("UC") {
                let result = try await InnertubeDetail.shared.browseArtist(browseId: browseId, force: force)
                guard generation == PageSession.generation(), pageRequestID == request, !Task.isCancelled else { return }
                page = result
                if page?.songs.isEmpty == true {
                    let result = try await InnertubeDetail.shared.browse(browseId: browseId, force: force)
                guard generation == PageSession.generation(), pageRequestID == request, !Task.isCancelled else { return }
                page = result
                }
            } else {
                let result = try await InnertubeDetail.shared.browse(browseId: browseId, force: force)
                guard generation == PageSession.generation(), pageRequestID == request, !Task.isCancelled else { return }
                page = result
            }
            saved = page?.librarySaved ?? false
            continuation = page?.continuation
            suggested = page?.suggestedSongs ?? []
        } catch {
            guard generation == PageSession.generation(), pageRequestID == request, !Task.isCancelled else { return }
            if page == nil { self.error = error.localizedDescription }
        }
        guard generation == PageSession.generation(), pageRequestID == request, !Task.isCancelled else { return }
        loading = false
        if error == nil { await DownloadStore.shared.syncIfOwned(browseId: browseId) }
    }

    private func loadMore() async {
        guard let token = continuation, !token.isEmpty else { return }
        let generation = PageSession.generation()
        let request = pageRequestID
        continuation = nil
        guard let extra = try? await InnertubeDetail.shared.more(token: token),
              generation == PageSession.generation(), !Task.isCancelled,
              pageRequestID == request, var page else { return }
        let known = Set(page.songs.map(\.videoId))
        page.songs.append(contentsOf: extra.songs.filter { !known.contains($0.videoId) })
        suggested.append(contentsOf: extra.suggestedSongs)
        continuation = extra.continuation
        self.page = page
    }

    private func toggleSave(_ page: DetailPageModel) async {
        guard let pid = page.libraryPlaylistId else { return }
        let generation = PageSession.generation()
        saving = true
        let next = !saved
        let failure = await LibraryActions.ratePlaylist(playlistId: pid, saved: next)
        guard generation == PageSession.generation(), !Task.isCancelled else { return }
        if failure == nil { saved = next }
        saving = false
    }

    private func toggleSubscription(_ subscription: ArtistSubscriptionPayload, artistName: String) async {
        guard !subscribing else { return }
        let generation = PageSession.generation()
        subscribing = true
        let wasSubscribed = subscriptionOverride ?? subscription.subscribed
        let next = !wasSubscribed
        subscriptionOverride = next
        let failure = await LibraryActions.setSubscribed(channelId: subscription.channelId, subscribed: next)
        guard generation == PageSession.generation(), !Task.isCancelled else { return }
        if let failure {
            subscriptionOverride = wasSubscribed
            toast.show("Couldn’t update subscription: \(failure)", kind: .failure)
        } else {
            toast.show(next ? "Subscribed to \(artistName)" : "Unsubscribed from \(artistName)")
        }
        subscribing = false
    }

    private func setPrivacy(_ value: String) async {
        privacy = value
        _ = await LibraryActions.setPlaylistPrivacy(playlistId: browseId, privacy: value)
    }

    private func removeDuplicates(_ page: DetailPageModel) async {
        let generation = PageSession.generation()
        let pairs = page.songs.compactMap { song -> (setVideoId: String, videoId: String)? in
            guard let setVideoId = song.setVideoId else { return nil }
            return (setVideoId, song.videoId)
        }
        let failure = await LibraryActions.removeDuplicates(playlistId: browseId, songs: pairs)
        guard generation == PageSession.generation(), !Task.isCancelled, failure == nil else { return }
        var seen = Set<String>()
        var kept: [DetailPageModel.SongPayload] = []
        for song in page.songs {
            if seen.insert(song.videoId).inserted { kept.append(song) }
        }
        var next = page
        next.songs = kept
        self.page = next
    }

    private func reorder(from source: IndexSet, to dest: Int) async {
        guard var page else { return }
        page.songs.move(fromOffsets: source, toOffset: dest)
        self.page = page
        guard let from = source.first else { return }
        let movedIndex = dest > from ? dest - 1 : dest
        guard page.songs.indices.contains(movedIndex), let setVideoId = page.songs[movedIndex].setVideoId else { return }
        let successor = page.songs.indices.contains(movedIndex + 1) ? page.songs[movedIndex + 1].setVideoId : nil
        _ = await LibraryActions.movePlaylistItem(playlistId: browseId, setVideoId: setVideoId, successorSetVideoId: successor)
    }

    private func loadCanvas(_ page: DetailPageModel) async {
        guard kind(of: page) == .album,
              PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true) else {
            canvasURL = nil
            canvasFallbackURL = nil
            return
        }
        let credit = headerLines(page).credit.ifBlank { page.songs.first?.artist ?? "" }
        let title = page.title
        let json: String? = await withCheckedContinuation { cont in
            CanvasBridge.shared.lookupAlbum(album: title, artist: credit, callback: DetailCanvasCB { cont.resume(returning: $0) })
        }
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (obj["url"] as? String).flatMap(URL.init(string:)) else { return }
        canvasURL = url
        canvasFallbackURL = (obj["fallbackUrl"] as? String).flatMap(URL.init(string:))
    }
}

private extension String {
    func ifBlank(_ fallback: () -> String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback() : self
    }
}

private final class DetailCanvasCB: CanvasBridgeCanvasCallback {
    let handler: (String?) -> Void
    init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    func onResult(json: String?) { handler(json) }
}

// MARK: - Circular Action Buttons

private struct CircleIconButton: View {
    let icon: Image
    let label: String
    var size: CGFloat = 46
    var active: Bool = false
    var activeColor: Color? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(active ? (activeColor ?? .accentColor) : Color.primary.opacity(0.12))
                .overlay {
                    icon
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.44, height: size * 0.44)
                        .foregroundStyle(active ? Color.white : Color.primary)
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct PlayPill: View {
    var iconOnly: Bool = true
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if iconOnly {
                    Circle()
                        .fill(Color.white)
                        .overlay {
                            Image(systemName: "play.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: size * 0.40, height: size * 0.40)
                                .offset(x: 1.5)
                                .foregroundStyle(Color.black)
                        }
                        .frame(width: size, height: size)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Color.black)
                        Text("Play")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.black)
                    }
                    .padding(.horizontal, 24)
                    .frame(height: size)
                    .background(Color.white, in: Capsule())
                }
            }
            .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
    }
}

private struct CircleMenuButton<Content: View>: View {
    let label: String
    var size: CGFloat = 46
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Circle()
                .fill(Color.primary.opacity(0.12))
                .overlay {
                    Image(systemName: "ellipsis")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .accessibilityLabel(label)
        .help(label)
    }
}


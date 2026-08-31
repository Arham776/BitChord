import SwiftUI

/// Detail page for an album / artist / playlist browseId.
///
/// Layout follows macOS Music: large sleeve beside the title, accent-coloured
/// credit, Play / Shuffle capsules, then a track list. Every row shows art —
/// album tracks that omit a thumbnail inherit the page sleeve, same as
/// upstream (`song.thumbnailUrl ?: page.thumbnailUrl`), so the player cover
/// is never empty either.
struct DetailView: View {
    let browseId: String
    let initialTitle: String
    @Environment(PlaybackController.self) private var controller
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: DetailPageModel?
    @State private var error: String?
    @State private var loading = true
    @State private var headerArt: Data?
    @State private var filter = ""
    @State private var saved = false
    @State private var saving = false
    @State private var continuation: String?
    @State private var suggested: [DetailPageModel.SongPayload] = []
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var renameTitle = ""
    @State private var renamePresented = false

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
        .navigationTitle(page?.title.isEmpty == false ? page!.title : initialTitle)
        .alert("Rename Playlist", isPresented: $renamePresented) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                Task {
                    _ = await LibraryActions.renamePlaylist(playlistId: browseId, title: renameTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
    }

    private func loadedPage(_ page: DetailPageModel) -> some View {
        let tint = ArtworkPalette.pageTint(from: headerArt, seed: page.title.hashValue, dark: colorScheme == .dark)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(page, tint: tint)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 22)

                if !page.songs.isEmpty {
                    TextField("Filter songs", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 8)
                    trackList(page)
                        .padding(.horizontal, 16)
                } else if page.sections.isEmpty {
                    EmptyStateView(icon: Image(.bchMusicNote), title: "No tracks", subtitle: "This page has no playable tracks.", buttonTitle: nil, action: nil)
                }

                if !suggested.isEmpty {
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

                if let desc = page.description, !desc.isEmpty, kind(of: page) != .playlist {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind(of: page) == .artist ? "About the artist" : "About the album")
                            .font(.headline)
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                }

                ForEach(page.sections) { shelf in
                    ShelfCarousel(shelf: shelf)
                        .padding(.horizontal, 28)
                        .padding(.top, 28)
                }
            }
            .padding(.bottom, 28)
        }
        .background {
            pageWash(tint: tint)
        }
        .task(id: page.thumbnailUrl) {
            headerArt = await loadHeaderArt(page.thumbnailUrl)
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
            .frame(height: 420)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func header(_ page: DetailPageModel, tint: ArtworkPalette.PageTint) -> some View {
        let lines = headerLines(page)
        let artSide: CGFloat = kind(of: page) == .artist ? 180 : 200
        return HStack(alignment: .bottom, spacing: 24) {
            ArtworkView(url: page.thumbnailUrl, data: headerArt, side: artSide)
                .clipShape(.rect(cornerRadius: kind(of: page) == .artist ? artSide / 2 : 12, style: .continuous))
                .shadow(color: .black.opacity(0.38), radius: 22, y: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(page.title.isEmpty ? initialTitle : page.title)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                if !lines.credit.isEmpty {
                    Text(lines.credit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint.accent)
                        .lineLimit(1)
                }

                if !lines.meta.isEmpty {
                    Text(lines.meta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                        .textCase(.uppercase)
                }

                if let sub = page.subscriberCountText, !sub.isEmpty, kind(of: page) == .artist {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if page.songs.count > 0 {
                    HStack(spacing: 10) {
                        Button {
                            controller.play(page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }, at: 0)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint.accent)
                        .controlSize(.large)

                        Button {
                            var shuffled = page.songs.map { toEntry($0, fallbackArt: fallbackArt(page)) }
                            shuffled.shuffle()
                            controller.play(shuffled, at: 0)
                        } label: {
                            Label {
                                Text("Shuffle")
                            } icon: {
                                Image(.bchShuffle)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 13, height: 13)
                            }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint.accent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: 340)
                    .padding(.top, 10)

                    if auth.signedIn, kind(of: page) != .artist {
                        Button {
                            Task { await toggleSave(page) }
                        } label: {
                            Label(saved ? "Saved" : "Save to Library", systemImage: saved ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    }
                    if kind(of: page) == .playlist, page.playlistOwned == true {
                        Button("Rename Playlist…") {
                            renameTitle = page.title
                            renamePresented = true
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Download") {
                        Task { await DownloadStore.shared.downloadCollection(browseId: browseId) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func trackList(_ page: DetailPageModel) -> some View {
        let fallback = page.thumbnailUrl
        let songs = page.songs.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter)
        }
        return LazyVStack(spacing: 0) {
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
        guard let url, let endpoint = URL(string: SharedArtwork.sized(url, 720) ?? url) else { return nil }
        return (try? await URLSession.shared.data(from: endpoint))?.0
    }

    private func load() async {
        loading = true
        error = nil
        do {
            if browseId.hasPrefix("UC") {
                page = try await InnertubeDetail.shared.browseArtist(browseId: browseId)
                if page?.songs.isEmpty == true {
                    page = try await InnertubeDetail.shared.browse(browseId: browseId)
                }
            } else {
                page = try await InnertubeDetail.shared.browse(browseId: browseId)
            }
            saved = page?.librarySaved ?? false
            continuation = page?.continuation
            suggested = page?.suggestedSongs ?? []
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadMore() async {
        guard let token = continuation, !token.isEmpty else { return }
        continuation = nil
        guard let extra = try? await InnertubeDetail.shared.more(token: token), var page else { return }
        let known = Set(page.songs.map(\.videoId))
        page.songs.append(contentsOf: extra.songs.filter { !known.contains($0.videoId) })
        suggested.append(contentsOf: extra.suggestedSongs)
        continuation = extra.continuation
        self.page = page
    }

    private func toggleSave(_ page: DetailPageModel) async {
        guard let pid = page.libraryPlaylistId else { return }
        saving = true
        let next = !saved
        if await LibraryActions.ratePlaylist(playlistId: pid, saved: next) == nil {
            saved = next
        }
        saving = false
    }
}

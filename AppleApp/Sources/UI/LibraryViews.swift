import SwiftUI
import BitChordShared
import UniformTypeIdentifiers

/// Home tab — upstream's "Play" tab: signed out it leads with the sign-in
/// banner over the anonymous home feed (FEmusic_home + new releases),
/// skeleton while loading, retry on error. Local music lives in Library.
struct HomeView: View {
    @Bindable var feed: FeedLoader
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Home")
                .refreshable { await feed.load(force: true, epoch: auth.sessionEpoch) }
                .task(id: auth.sessionEpoch) { await feed.load(force: false, epoch: auth.sessionEpoch) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.phase {
        case .loading:
            ScrollView { FeedSkeleton() }
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "Your feed couldn't load",
                subtitle: message,
                buttonTitle: "Retry"
            ) { Task { await feed.load() } }
        case .loaded(let shelves):
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !auth.signedIn {
                        SignInBanner { auth.loginPresented = true }
                    }
                    ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                        if index == 0, shelf.items.count > 2 {
                            HeroShelf(shelf: shelf)
                                .onAppear {
                                    if shelf.id == shelves.last?.id { Task { await feed.loadMore() } }
                                }
                        } else {
                            ShelfCarousel(shelf: shelf)
                                .onAppear {
                                    if shelf.id == shelves.last?.id {
                                        Task { await feed.loadMore() }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }
}

/// Explore tab — the same shelf rendering as Home over upstream's
/// FEmusic_explore + FEmusic_charts pairing; no sign-in banner here.
struct ExploreView: View {
    @Bindable var feed: FeedLoader
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Explore")
                .refreshable { await feed.load(force: true, epoch: auth.sessionEpoch) }
                .task(id: auth.sessionEpoch) { await feed.load(force: false, epoch: auth.sessionEpoch) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.phase {
        case .loading:
            ScrollView { FeedSkeleton() }
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchExplore),
                title: "Nothing to explore right now",
                subtitle: message,
                buttonTitle: "Retry"
            ) { Task { await feed.load() } }
        case .loaded(let shelves):
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(shelves) { shelf in
                        ShelfCarousel(shelf: shelf)
                            .onAppear {
                                if shelf.id == shelves.last?.id {
                                    Task { await feed.loadMore() }
                                }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }
}

/// Library tab — library sub-destinations group in the sidebar on macOS
/// (UI spec §2 TabSection) and list on iOS: Songs, Albums, Artists, Downloads
/// from the local scan, plus History.
struct LibraryView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    @State private var section: Section = .songs
    /// When set (macOS sidebar `TabSection` rows), the picker is hidden and
    /// this destination is shown directly.
    var lockedSection: Section? = nil

    enum Section: String, CaseIterable, Identifiable {
        case youtube, songs, albums, artists, downloads, history
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: "Recent"
            default: rawValue.capitalized
            }
        }
    }

    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(lockedSection?.label ?? "Library")
                .toolbar {
                    ToolbarItem {
                        Button {
                            pickFolder()
                        } label: {
                            Image(.bchPlus)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 15)
                        }
                        .help("Scan a folder")
                    }
                }
                .onAppear {
                    if lockedSection != nil { return }
                    if auth.signedIn, section == .songs {
                        section = .youtube
                    }
                }
                .onChange(of: auth.signedIn) { _, signedIn in
                    guard lockedSection == nil else { return }
                    if signedIn { section = .youtube }
                    else if section == .youtube { section = .songs }
                }
                .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        local.scanPicked(url)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch lockedSection ?? section {
        case .youtube: youtubeLibrary
        case .songs: songsList
        case .albums: albumGrid
        case .artists: artistList
        case .downloads: downloadsList
        case .history:
            HistoryView()
                .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
        }
    }

    private var showsPicker: Bool { lockedSection == nil }

    private var picker: some View {
        HStack {
            Picker("Section", selection: $section) {
                ForEach(visibleSections) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var visibleSections: [Section] {
        auth.signedIn ? Section.allCases : Section.allCases.filter { $0 != .youtube }
    }

    private var youtubeLibrary: some View {
        YoutubeLibraryView()
            .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
    }

    private func pickFolder() {
#if os(macOS)
        local.chooseFolder()
#else
        pickingFolder = true
#endif
    }

    private var downloadsList: some View {
        let store = DownloadStore.shared
        return Group {
            if store.items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No downloads yet",
                    subtitle: "Save a track from Now Playing — BitChord tags it and keeps it here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, track in
                            SongRow(
                                entry: QueueEntry(
                                    id: track.path, title: track.title, artist: track.artist,
                                    source: track.path, thumbnailUrl: nil, durationText: nil,
                                    albumName: track.album.isEmpty ? nil : track.album,
                                    artworkData: track.artwork, isLocal: true
                                ),
                                play: {
                                    controller.play(store.items.map {
                                        QueueEntry(id: $0.path, title: $0.title, artist: $0.artist, source: $0.path, thumbnailUrl: nil, durationText: nil, albumName: $0.album.isEmpty ? nil : $0.album, artworkData: $0.artwork, isLocal: true)
                                    }, at: index)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
        .onAppear { store.refresh() }
    }

    private var songsList: some View {
        Group {
            if !local.scanned {
                VStack(spacing: 16) {
                    if lockedSection == nil {
                        ReplayBanner { appModel.replayPresented = true }
                            .padding(.horizontal, 24)
                    }
                    EmptyStateView(
                        icon: Image(.bchLibrary),
                        title: "Scan your music",
                        subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                        buttonTitle: "Choose Folder"
                    ) { pickFolder() }
                }
            } else if local.tracks.isEmpty {
                EmptyStateView(
                    icon: Image(.bchMusicNote),
                    title: "No audio files here",
                    subtitle: "The folder you selected didn't contain any supported audio files.",
                    buttonTitle: "Choose Another Folder"
                ) { pickFolder() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(local.tracks.enumerated()), id: \.element.id) { index, track in
                            SongRow(
                                entry: QueueEntry.from(track),
                                play: { controller.play(local.tracks.map(QueueEntry.from), at: index) },
                                playNext: { controller.playNext(QueueEntry.from(track)) },
                                addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
    }

    private var albumGrid: some View {
        Group {
            if local.albumGroups.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No albums yet",
                    subtitle: "Albums group themselves once a folder with tagged music is scanned.",
                    buttonTitle: "Choose Folder"
                ) { pickFolder() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                        ForEach(local.albumGroups, id: \.name) { group in
                            Button {
                                controller.play(group.tracks.map(QueueEntry.from), at: 0)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(url: nil, data: group.tracks.first?.artwork, side: 170)
                                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                                    Text(group.name)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text(group.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
            }
        }
    }

    private var artistList: some View {
        Group {
            if local.artistGroups.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No artists yet",
                    subtitle: "Artists group themselves once a folder with tagged music is scanned.",
                    buttonTitle: "Choose Folder"
                ) { pickFolder() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(local.artistGroups, id: \.name) { group in
                            ArtistGroupRow(group: group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
            }
        }
    }
}

/// One artist with an expandable track list (tap plays the artist's songs).
private struct ArtistGroupRow: View {
    let group: (name: String, tracks: [LocalTrack])
    @Environment(PlaybackController.self) private var controller
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text(group.name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    SongRow(
                        entry: QueueEntry.from(track),
                        play: { controller.play(group.tracks.map(QueueEntry.from), at: index) }
                    )
                }
            }
        }
    }
}

/// Listening history page — signed-in `FEmusic_history`, newest first.
struct HistoryView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @State private var songs: [YouTubeSong] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "Sign in to see history",
                    subtitle: "Plays on this account show up here, newest first.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "History couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if songs.isEmpty {
                EmptyStateView(
                    icon: Image(.bchClock),
                    title: "No listening history yet",
                    subtitle: "Tracks you play will show up here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRow(
                                entry: QueueEntry(
                                    id: song.videoId, title: song.title, artist: song.artist,
                                    source: "yt:\(song.videoId)", thumbnailUrl: song.thumbnailUrl,
                                    durationText: song.durationText, albumName: song.albumName,
                                    artworkData: nil, isLocal: false
                                ),
                                play: {
                                    controller.play(songs.map {
                                        QueueEntry(
                                            id: $0.videoId, title: $0.title, artist: $0.artist,
                                            source: "yt:\($0.videoId)", thumbnailUrl: $0.thumbnailUrl,
                                            durationText: $0.durationText, albumName: $0.albumName,
                                            artworkData: nil, isLocal: false
                                        )
                                    }, at: index)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func load() async {
        guard auth.signedIn else {
            loading = false
            songs = []
            return
        }
        loading = true
        error = nil
        do {
            songs = try await InnertubeFeed.shared.history()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Signed-in YouTube Music library: playlists, albums, artists.
private struct YoutubeLibraryView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Sign in for your library",
                    subtitle: "Liked playlists, albums and artists live here.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ScrollView { FeedSkeleton() }
            } else if let error {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Library couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if shelves.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Nothing saved yet",
                    subtitle: "Playlists, albums and artists you save show up here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ReplayBanner { appModel.replayPresented = true }
                        Button("New Playlist") {
                            appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                        }
                        .buttonStyle(.bordered)
                        ForEach(pinnedShelves(shelves)) { shelf in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(shelf.title).font(.title3.weight(.bold))
                                    Spacer()
                                    if shelf.items.count > 8 {
                                        NavigationLink("Show all") {
                                            LibraryGridView(title: shelf.title, items: shelf.items)
                                        }
                                        .font(.callout)
                                    }
                                }
                                ShelfCarousel(shelf: FeedShelf(title: "", items: shelf.items, subtitle: nil))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load() }
            }
        }
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func pinnedShelves(_ shelves: [FeedShelf]) -> [FeedShelf] {
        let pinned = PlatformSettings.shared.getString(key: "pinned_playlists", default: "")
            .split(separator: ",").map(String.init)
        return shelves.map { shelf in
            let items = shelf.items.sorted { a, b in
                let ap = pinned.contains(a.browseId ?? "")
                let bp = pinned.contains(b.browseId ?? "")
                if ap == bp { return false }
                return ap && !bp
            }
            return FeedShelf(title: shelf.title, items: items, subtitle: shelf.subtitle)
        }
    }

    private func load() async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        loading = true
        error = nil
        do {
            shelves = try await InnertubeFeed.shared.library()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct LibraryGridView: View {
    let title: String
    let items: [ShelfCard]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(items) { card in
                    ShelfCardView(card: card)
                }
            }
            .padding(24)
        }
        .navigationTitle(title)
    }
}

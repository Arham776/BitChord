import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
                    local.restoreViewPreferences()
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
                List {
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
                        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                }
                .listStyle(.plain)
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
            } else if local.visibleTracks.isEmpty {
                // A search that matched nothing is not the same as a library with
                // nothing in it, and the empty state says which.
                EmptyStateView(
                    icon: Image(.bchSearch),
                    title: local.query.isEmpty ? "No audio files here" : "Nothing matches",
                    subtitle: local.query.isEmpty
                        ? "The folder you selected didn't contain any supported audio files."
                        : "No track in this library matches \u{201C}\(local.query)\u{201D}.",
                    buttonTitle: local.query.isEmpty ? "Choose Another Folder" : nil,
                    action: local.query.isEmpty ? { pickFolder() } : nil
                )
            } else {
                songsContent
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if showsPicker { picker }
                if local.scanned { songsToolbar }
            }
        }
    }

    /// The search field, the sort menu and the list/grid toggle.
    ///
    /// In a `safeAreaInset` rather than inside the scroll view, so it stays put
    /// while a long library moves under it — the same place a Mac user expects a
    /// filter to be, and the only arrangement where it is reachable without
    /// scrolling back to the top.
    private var songsToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter this library", text: Bindable(local).query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter this library")
                if !local.query.isEmpty {
                    Button {
                        local.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Menu {
                Picker("Sort By", selection: Bindable(local).sort) {
                    ForEach(local.sortOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(local.sort.label, systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort this library")

            Picker("View", selection: Bindable(local).viewType) {
                ForEach(LocalViewType.allCases) { type in
                    Image(systemName: type.symbol).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            .help("List or grid")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var songsContent: some View {
        switch local.viewType {
        case .list:
            List {
                ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                    SongRow(
                        entry: QueueEntry.from(track),
                        play: {
                            // The queue is what is on screen, in the order on
                            // screen — playing from `tracks` instead would start at
                            // whichever track the sort put first rather than the one
                            // tapped.
                            let shown = local.visibleTracks
                            controller.play(shown.map(QueueEntry.from), at: index)
                        },
                        playNext: { controller.playNext(QueueEntry.from(track)) },
                        addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                }
            }
            .listStyle(.plain)
        case .grid:
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)],
                    spacing: 20
                ) {
                    ForEach(local.visibleTracks) { track in
                        LocalTrackCard(track: track) {
                            controller.play(local.visibleTracks.map(QueueEntry.from))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
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
                List {
                    ForEach(local.artistGroups, id: \.name) { group in
                        ArtistGroupRow(group: group)
                            .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                    }
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if showsPicker { picker } }
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
                List {
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
                            .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                }
                .listStyle(.plain)
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

/// One local track as a card, for the grid.
///
/// Artwork first because that is the point of a grid: the reason to look at a
/// collection rather than search it. A file with no embedded artwork gets a
/// generated tile from its own initials rather than a blank square, so a library
/// of untagged files is still recognisable at a glance.
private struct LocalTrackCard: View {
    let track: LocalTrack
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(track.title) — \(track.artist)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityHint("Plays this track")
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = track.artwork, hasArtwork(data) {
            decoded(data)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Text(initials)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether this data decodes to an image at all.
    ///
    /// Separate from [decoded] because the card body is a `ViewBuilder`, and a
    /// guard around a view-building call cannot be expressed without either
    /// decoding twice or letting a bad image through.
    private func hasArtwork(_ data: Data) -> Bool {
        #if os(macOS)
        return NSImage(data: data) != nil
        #else
        return UIImage(data: data) != nil
        #endif
    }

    /// The embedded artwork.
    ///
    /// Two spellings because the type is genuinely two types — `UIImage` on iOS,
    /// `NSImage` on macOS — and `Image` initialises from each under a different
    /// label. Wrapped so the card body above reads as one thing rather than as a
    /// platform conditional.
    @ViewBuilder
    private func decoded(_ data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        }
        #endif
    }

    /// Up to two initials from the title, falling back to the artist.
    private var initials: String {
        let source = track.title.isEmpty ? track.artist : track.title
        let words = source.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "♪" : letters.joined().uppercased()
    }
}

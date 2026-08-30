import SwiftUI
import BitChordShared

/// Home tab — upstream's "Play" tab: signed out it leads with the sign-in
/// banner over the anonymous home feed (FEmusic_home + new releases),
/// skeleton while loading, retry on error. Local music lives in Library.
struct HomeView: View {
    @State private var feed = FeedLoader(.home)
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Home")
                .task { await feed.load() }
                .onChange(of: auth.sessionEpoch) { _, _ in
                    Task { await feed.load() }
                }
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
                    if let err = controller.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.85), in: .rect(cornerRadius: 8))
                    }
                    if !auth.signedIn {
                        SignInBanner { auth.loginPresented = true }
                    }
                    ForEach(shelves) { shelf in
                        ShelfCarousel(shelf: shelf)
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
    @State private var feed = FeedLoader(.explore)
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Explore")
                .task { await feed.load() }
                .onChange(of: auth.sessionEpoch) { _, _ in
                    Task { await feed.load() }
                }
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
                    if let err = controller.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.85), in: .rect(cornerRadius: 8))
                    }
                    ForEach(shelves) { shelf in
                        ShelfCarousel(shelf: shelf)
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
    @State private var local = LocalLibrary.shared
    @State private var section: Section = .songs

    enum Section: String, CaseIterable, Identifiable {
        case songs, albums, artists, history
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem {
                        Button {
                            local.chooseFolder()
                        } label: {
                            Image(.bchPlus)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 15)
                        }
                        .help("Scan a folder")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .songs: songsList
        case .albums: albumGrid
        case .artists: artistList
        case .history:
            HistoryView()
        }
    }

    private var picker: some View {
        HStack {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var songsList: some View {
        Group {
            if !local.scanned {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Scan your music",
                    subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                    buttonTitle: "Choose Folder"
                ) { local.chooseFolder() }
            } else if local.tracks.isEmpty {
                EmptyStateView(
                    icon: Image(.bchMusicNote),
                    title: "No audio files here",
                    subtitle: "The folder you selected didn't contain any supported audio files.",
                    buttonTitle: "Choose Another Folder"
                ) { local.chooseFolder() }
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
        .safeAreaInset(edge: .top, spacing: 0) { picker }
    }

    private var albumGrid: some View {
        Group {
            if local.albumGroups.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No albums yet",
                    subtitle: "Albums group themselves once a folder with tagged music is scanned.",
                    buttonTitle: "Choose Folder"
                ) { local.chooseFolder() }
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
                .safeAreaInset(edge: .top, spacing: 0) { picker }
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
                ) { local.chooseFolder() }
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
                .safeAreaInset(edge: .top, spacing: 0) { picker }
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

/// Listening history page (spec §5 HistoryScreen → HistoryView).
struct HistoryView: View {
    var body: some View {
        EmptyStateView(
            icon: Image(.bchClock),
            title: "No listening history yet",
            subtitle: "Tracks you play will show up here.",
            buttonTitle: nil, action: nil
        )
    }
}

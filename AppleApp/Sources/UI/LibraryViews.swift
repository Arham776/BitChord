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
                .navigationTitle("Listen Now")
                .toolbar {
                    #if os(iOS)
                    // Match upstream FrostedTopBar's root-page leading mark.
                    // Keep Home as the large in-feed title while the brand mark
                    // occupies the top bar's leading position.
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarLeadingMark()
                    }
                    ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    #endif
                }
                .refreshable { await feed.load(force: true, epoch: auth.sessionEpoch) }
                .task(id: auth.sessionEpoch) { await feed.load(force: false, epoch: auth.sessionEpoch) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.phase {
        case .loading:
            ScrollView { HomeFeedSkeleton() }
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
                        if index == 0, isRecentsShelf(shelf) {
                            RecentShelf(shelf: shelf)
                                .onAppear {
                                    if shelf.id == shelves.last?.id { Task { await feed.loadMore() } }
                                }
                        } else if index == 0, shelf.items.count > 2 {
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

    /// Upstream's `RECENTS_TITLE` — the first shelf is a recents rail when the
    /// service titles it so, matched case-insensitively like upstream.
    private func isRecentsShelf(_ shelf: FeedShelf) -> Bool {
        let title = shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the earlier Apple bridge title as well as upstream's canonical
        // "Recents" so a cached feed still gets the four-row treatment.
        return title == "recents" || title == "recently played"
    }
}

/// The upstream Home loading state reserves the Recents shelf and matches the
/// saved list/grid layout so content does not jump when the feed arrives.
private struct HomeFeedSkeleton: View {
    @State private var viewType = PlatformSettings.shared.getString(
        key: "home_recents_view_type", default: "LIST"
    )

    private var isList: Bool { viewType.uppercased() != "GRID" }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RecentsSkeletonBlock(height: 22, cornerRadius: 6).frame(width: 112)
                    Spacer(minLength: 8)
                    RecentsSkeletonBlock(height: 32, cornerRadius: 16).frame(width: 32)
                }
                if isList {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { index in
                                HStack(spacing: 12) {
                                    RecentsSkeletonBlock(height: 48, cornerRadius: 7).frame(width: 48)
                                    VStack(alignment: .leading, spacing: 7) {
                                        RecentsSkeletonBlock(height: 14, cornerRadius: 4)
                                            .frame(width: [150.0, 112.0, 134.0, 96.0][index])
                                        RecentsSkeletonBlock(height: 12, cornerRadius: 4)
                                            .frame(width: [92.0, 122.0, 78.0, 106.0][index])
                                    }
                                    Spacer(minLength: 4)
                                    RecentsSkeletonBlock(height: 20, cornerRadius: 10).frame(width: 20)
                                }
                                .frame(height: 56)
                            }
                        }
                        .frame(width: min(geometry.size.width * 0.88, 400), alignment: .leading)
                    }
                    .frame(height: 4 * 56)
                } else {
                    GeometryReader { geometry in
                        let cardWidth = min(geometry.size.width * 0.70, 320.0)
                        HStack(spacing: 14) {
                            ForEach(0..<2, id: \.self) { _ in
                                RecentsSkeletonBlock(height: cardWidth / 0.92, cornerRadius: 18)
                                    .frame(width: cardWidth)
                            }
                        }
                    }
                    .frame(maxWidth: 320 / 0.70)
                    .aspectRatio(0.92 / 0.70, contentMode: .fit)
                }
            }
            ForEach(0..<2, id: \.self) { shelf in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 22, cornerRadius: 6).frame(width: shelf == 0 ? 140 : 110)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(height: 156, cornerRadius: 12).frame(width: 156)
                                    SkeletonBlock(height: 14, cornerRadius: 4).frame(width: 118)
                                    SkeletonBlock(height: 12, cornerRadius: 4).frame(width: 82)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

/// The Recents placeholder uses the same moving highlight sweep as upstream's
/// shimmer blocks, while respecting the listener's Reduce Motion setting.
private struct RecentsSkeletonBlock: View {
    let height: CGFloat
    var cornerRadius: CGFloat = 6
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.55)
                    .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.55)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
        .onAppear { sweep = true }
        .animation(
            reduceMotion ? nil : .linear(duration: 1.4).repeatForever(autoreverses: false),
            value: sweep
        )
        .accessibilityHidden(true)
    }
}

/// Upstream's `RecentShelf`: the first Home shelf when titled "Recents".
/// LIST mode is a horizontal rail of two columns × four track rows;
/// GRID mode is the ordinary card carousel. The choice persists in
/// `home_recents_view_type` like upstream's `homeRecentsViewType`.
struct RecentShelf: View {
    let shelf: FeedShelf
    @Environment(PlaybackController.self) private var controller

    /// LIST or GRID, persisted. Read off `PlatformSettings` rather than
    /// `@AppStorage` so the value is the same store the Android side reads.
    @State private var viewType: String = PlatformSettings.shared.getString(
        key: "home_recents_view_type", default: "LIST"
    )

    private var isList: Bool { viewType.uppercased() != "GRID" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recents").font(.title2.weight(.bold)).lineLimit(1)
                    if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    viewType = isList ? "GRID" : "LIST"
                    PlatformSettings.shared.putString(key: "home_recents_view_type", value: viewType)
                } label: {
                    Image(isList ? .bchGridView : .bchListView)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help(isList ? "Switch to grid view" : "Switch to list view")
                .accessibilityLabel(isList ? "Switch to grid view" : "Switch to list view")
            }
            if isList {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(shelf.items.chunked(4).enumerated()), id: \.offset) { _, column in
                                VStack(spacing: 0) {
                                    ForEach(column) { card in
                                        RecentTrackRow(card: card)
                                    }
                                }
                                // Upstream's trackColumnWidth is 88% of the
                                // viewport, capped at 400 points.
                                .frame(width: min(geometry.size.width * 0.88, 400), alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: 4 * 56 + 4)
                .padding(.horizontal, -24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { card in
                            ShelfCardView(card: card)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// One recent track: 48pt sleeve, title/artist, overflow menu. Matches
/// upstream's `RecentTrackRow` (artwork + two lines + more button).
private struct RecentTrackRow: View {
    let card: ShelfCard
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let videoId = card.videoId, !videoId.isEmpty {
                    controller.playRadio(QueueEntry.youtube(
                        videoId: videoId, title: card.title, artist: card.subtitle ?? "",
                        thumbnailUrl: card.thumbnailUrl
                    ), context: "Recents")
                }
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: card.thumbnailUrl, data: nil, side: 48)
                        .clipShape(.rect(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.body.weight(.medium)).lineLimit(1)
                        if let subtitle = card.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu { actionMenu }

            Menu { actionMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .tint(.gray)
            .accessibilityLabel("More actions for \(card.title)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionMenu: some View {
        if let videoId = card.videoId, !videoId.isEmpty {
            SongActionButtons(entry: QueueEntry.youtube(
                videoId: videoId, title: card.title, artist: card.subtitle ?? "",
                thumbnailUrl: card.thumbnailUrl
            ))
        } else {
            BrowseActionButtons(card: card)
        }
    }
}

private extension Array {
    /// Splits into consecutive runs of `size`, like Kotlin's `chunked`.
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(Array(self[index..<end]))
            index = end
        }
        return out
    }
}

/// Explore tab — upstream shows mood and genre categories here.
struct ExploreView: View {
    @State private var moods = MoodGenreLoader()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Explore")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarLeadingMark()
                    }
                    ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    #endif
                }
                .refreshable {
                    await moods.load(force: true)
                }
                .task {
                    await moods.load(force: false)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch moods.phase {
        case .loading:
            ScrollView { moodGrid.padding(.horizontal, 24).padding(.vertical, 20) }
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchExplore),
                title: "Nothing to explore right now",
                subtitle: message,
                buttonTitle: "Retry"
            ) { Task { await moods.load(force: true) } }
        case .loaded:
            ScrollView {
                moodGrid
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var moodGrid: some View {
        switch moods.phase {
        case .loading:
            // A grid of placeholder squares sized as real tiles to avoid layout jumping.
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 140, height: 22)
                LazyVGrid(columns: Self.moodColumns, spacing: 14) {
                    ForEach(0..<10, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary)
                            .frame(height: 100)
                    }
                }
            }
        case .failed:
            EmptyView()
        case .loaded(let sections):
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    LazyVGrid(columns: Self.moodColumns, spacing: 14) {
                        ForEach(section.items) { item in
                            NavigationLink {
                                MoodGenrePlaylistsView(category: item)
                            } label: {
                                MoodTile(category: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    /// Two across on iPhone like upstream's `MoodGenreGrid` (pairs chunked by
    /// two at half the guttered width); adaptive on Mac, where a fixed pair
    /// would read as a list in a wide window.
    #if os(iOS)
    private static let moodColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]
    #else
    private static let moodColumns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
    #endif
}

/// One category button: a 100pt gradient card with a rotated sleeve cropped
/// past the bottom-end corner and the title at the top-start — upstream's
/// `MoodGenreCard` (16° rotation, 82pt art, bold white title).
private struct MoodTile: View {
    let category: MoodGenre

    /// Kotlin String.hashCode uses UTF-16 units and a 31 multiplier.
    private var colorIndex: Int {
        let hash = category.title.utf16.reduce(Int32(0)) { value, unit in
            value &* 31 &+ Int32(unit)
        }
        return Int((UInt32(bitPattern: hash) & 0x7fff_ffff) % 8)
    }

    private var baseRGB: (Double, Double, Double) {
        let colors: [(Int, Int, Int)] = [
            (0xE6, 0x4A, 0x19), (0xEC, 0x0B, 0x65),
            (0x86, 0x64, 0xAC), (0x6B, 0x4E, 0xFF),
            (0xBE, 0x61, 0x00), (0x23, 0x3C, 0x78),
            (0x4D, 0x97, 0xE5), (0xAA, 0x26, 0x7E),
        ]
        let (r, g, b) = colors[colorIndex]
        return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            let (r, g, b) = baseRGB
            LinearGradient(
                colors: [
                    Color(red: r, green: g, blue: b),
                    Color(red: r * 0.68, green: g * 0.68, blue: b * 0.68),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // A rotated sleeve cropped past the corner, like a cropped album
            // sleeve rather than a floating rectangle.
            GeometryReader { _ in
                Color.clear
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                    if let url = category.thumbnailUrl {
                        ArtworkView(url: url, data: nil, side: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(width: 82, height: 82)
                .rotationEffect(.degrees(16))
                .offset(x: 10, y: 12)
                .shadow(color: .black.opacity(0.25), radius: 5, x: 2, y: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(category.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .lineLimit(2)
                .padding(12)
                .padding(.trailing, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .accessibilityLabel(category.title)
    }
}

/// The playlists behind one mood or genre category — upstream
/// `MoodGenrePlaylistsScreen`, a push rather than a sheet because it is a page
/// with its own scroll position and a back button, not an action on what is on
/// screen.
struct MoodGenrePlaylistsView: View {
    let category: MoodGenre
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var phase: LoadPhase = .loading

    enum LoadPhase { case loading, loaded, failed(String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ScrollView { FeedSkeleton() }
            case .failed(let message):
                EmptyStateView(
                    icon: Image(.bchExplore),
                    title: "Nothing here right now",
                    subtitle: message,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            case .loaded:
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(shelves) { shelf in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(shelf.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Spacer()
                                    if shelf.items.count > 5 {
                                        NavigationLink {
                                            LibraryGridView(title: shelf.title, items: shelf.items)
                                        } label: {
                                            HStack(spacing: 2) {
                                                Text("Show all")
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .font(.callout)
                                            .foregroundStyle(.tint)
                                        }
                                    }
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        ForEach(shelf.items) { card in
                                            ShelfCardView(card: card, preferTrack: true)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(category.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            shelves = try await InnertubeFeed.shared.moodGenreShelves(
                browseId: category.browseId, params: category.params
            )
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Loads the mood/genre categories, and their tile artwork afterwards.
///
/// The two-step shape is upstream's and it is deliberate: the grid is worth
/// painting before it is worth labelling with pictures, and the artwork comes
/// from the same cached response that backs each category's page, so a listener
/// who taps a category whose cover has already appeared does not pay for it
/// twice.
@MainActor @Observable
final class MoodGenreLoader {
    enum Phase { case loading, loaded([MoodGenreSection]), failed(String) }

    private(set) var phase: Phase = .loading
    private var loaded = false

    func load(force: Bool) async {
        if !force, loaded, case .loaded = phase { return }
        phase = .loading
        do {
            var sections = try await InnertubeFeed.shared.moodAndGenres()
            phase = .loaded(sections)
            loaded = true
            await fillArtwork(&sections)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Replaces the categories with ones carrying artwork, once each has
    /// answered. Published one section at a time so the first covers to arrive
    /// are on screen while the rest are still being asked for.
    private func fillArtwork(_ sections: inout [MoodGenreSection]) async {
        for index in sections.indices {
            for itemIndex in sections[index].items.indices {
                let item = sections[index].items[itemIndex]
                guard item.thumbnailUrl == nil else { continue }
                if let cover = await InnertubeFeed.shared
                    .moodGenreArtwork(browseId: item.browseId, params: item.params) {
                    sections[index].items[itemIndex].thumbnailUrl = cover
                    publish(sections)
                }
            }
        }
    }

    private func publish(_ sections: [MoodGenreSection]) {
        guard case .loaded = phase else { return }
        phase = .loaded(sections)
    }
}

/// Library tab — on iOS, renders upstream's unified LibraryScreen (Replay banner,
/// On Device cards, signed-in shelves). On macOS, when lockedSection is set from
/// the sidebar, directly displays that destination.
struct LibraryView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    /// When set (macOS sidebar `TabSection` rows), this destination is shown directly.
    var lockedSection: Section? = nil

    enum Section: String, CaseIterable, Identifiable {
        case youtube, songs, albums, artists, playlists, downloads, history, webdav
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: "Recent"
            case .webdav: "WebDAV"
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
                    #if os(iOS)
                    if lockedSection == nil {
                        ToolbarItem(placement: .topBarLeading) {
                            TopBarLeadingMark()
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if lockedSection == nil {
                            NavigationLink {
                                HistoryView()
                            } label: {
                                Image(systemName: "clock")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                            }
                            .buttonStyle(ProfileCircleButtonStyle())
                            .accessibilityLabel("Listening History")
                        }

                        Button {
                            pickFolder()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                        }
                        .buttonStyle(ProfileCircleButtonStyle())
                        .accessibilityLabel("Scan a folder")

                        TopBarAccountButton()
                    }
                    #else
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
                    #endif
                }
                .onAppear {
                    local.restoreViewPreferences()
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
        if let locked = lockedSection {
            switch locked {
            case .youtube: YoutubeLibraryView()
            case .songs: LocalMusicView(initialTab: .songs, onPickFolder: { pickFolder() })
            case .albums: LocalMusicView(initialTab: .albums, onPickFolder: { pickFolder() })
            case .artists: LocalMusicView(initialTab: .artists, onPickFolder: { pickFolder() })
            case .playlists: LocalPlaylistsView()
            case .downloads: DownloadsView()
            case .webdav: WebDavLibraryView()
            case .history: HistoryView()
            }
        } else {
            LibraryLandingView(onPickFolder: { pickFolder() })
        }
    }

    private func pickFolder() {
        #if os(macOS)
        local.chooseFolder()
        #else
        pickingFolder = true
        #endif
    }
}

/// Upstream's unified Library landing page (`LibraryScreen.kt`):
/// 1. Replay hero banner
/// 2. "On device" shelf: horizontal scroll with cards for Downloads, Local Music, WebDAV, History
/// 3. Signed-out prompt (if signed out)
/// 4. Signed-in shelves (if signed in): Playlists (with NewPlaylistTile and pinned first), Albums, Artists
struct LibraryLandingView: View {
    var onPickFolder: () -> Void
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(PlaybackController.self) private var controller
    @State private var downloadStore = DownloadStore.shared
    @State private var local = LocalLibrary.shared
    @State private var shelves: [FeedShelf] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // 1. Replay Banner
                ReplayBanner { appModel.replayPresented = true }

                // 2. On Device Shelf
                onDeviceShelf

                // 3. Signed-out prompt or Signed-in shelves
                if !auth.signedIn {
                    signedInPrompt
                } else if loading {
                    FeedSkeleton()
                } else if let error {
                    EmptyStateView(
                        icon: Image(.bchLibrary),
                        title: "Library couldn't load",
                        subtitle: error,
                        buttonTitle: "Retry"
                    ) { Task { await loadShelves() } }
                } else {
                    signedInShelves
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .refreshable {
            downloadStore.refresh()
            await loadShelves()
        }
        .task(id: auth.sessionEpoch) {
            downloadStore.refresh()
            await loadShelves()
        }
    }

    private var onDeviceShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On device")
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    OnDeviceCard(
                        title: "Downloads",
                        subtitle: "\(downloadStore.items.count) downloaded song\(downloadStore.items.count == 1 ? "" : "s")",
                        systemImage: "arrow.down.circle.fill",
                        tintColor: .accentColor,
                        destination: DownloadsView()
                    )

                    OnDeviceCard(
                        title: "Local Music",
                        subtitle: local.scanned ? "\(local.tracks.count) song\(local.tracks.count == 1 ? "" : "s")" : "Choose folder",
                        systemImage: "folder.fill",
                        tintColor: .indigo,
                        destination: LocalMusicView(onPickFolder: onPickFolder)
                    )

                    OnDeviceCard(
                        title: "WebDAV",
                        subtitle: WebDavStore.shared.isConfigured ? "Connected" : "Not configured",
                        systemImage: "cloud.fill",
                        tintColor: .teal,
                        destination: WebDavLibraryView()
                    )

                    OnDeviceCard(
                        title: "History",
                        subtitle: "Listening history",
                        systemImage: "clock.fill",
                        tintColor: .orange,
                        destination: HistoryView()
                    )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var signedInPrompt: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text("Sign in for your library")
                .font(.headline)
            Text("Liked playlists, albums and artists you save show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In") {
                auth.loginPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var signedInShelves: some View {
        VStack(alignment: .leading, spacing: 26) {
            let sortedShelves = pinnedShelves(shelves)
            let hasPlaylists = sortedShelves.contains { isPlaylistsShelf($0) }

            // Upstream parity: fresh account has no Playlists shelf yet, but
            // needs the New Playlist tile to start one.
            if !hasPlaylists {
                shelfSection(FeedShelf(title: "Playlists", items: []))
            }

            ForEach(sortedShelves) { shelf in
                shelfSection(shelf)
            }
        }
    }

    private func shelfSection(_ shelf: FeedShelf) -> some View {
        let isPlaylists = isPlaylistsShelf(shelf)
        let totalCount = shelf.items.count + (isPlaylists ? 1 : 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(shelf.title).font(.title3.weight(.bold))
                Spacer()
                if totalCount > 5 {
                    NavigationLink {
                        LibraryGridView(title: shelf.title, items: shelf.items, isPlaylists: isPlaylists)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Show all")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.callout)
                        .foregroundStyle(.tint)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if isPlaylists {
                        NewPlaylistTile {
                            appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                        }
                    }
                    ForEach(displayItems(shelf)) { card in
                        ShelfCardView(card: card)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func pinnedShelves(_ shelves: [FeedShelf]) -> [FeedShelf] {
        let pinned = PlaylistPinning.pinnedIds()
        return shelves.map { shelf in
            guard isPlaylistsShelf(shelf) else { return shelf }
            let items = shelf.items.sorted { a, b in
                let ap = pinned.contains(a.browseId ?? "")
                let bp = pinned.contains(b.browseId ?? "")
                if ap == bp { return false }
                return ap && !bp
            }
            return FeedShelf(title: shelf.title, items: items, subtitle: shelf.subtitle)
        }
    }

    private func displayItems(_ shelf: FeedShelf) -> [ShelfCard] {
        let cap = isPlaylistsShelf(shelf) ? 4 : 5
        return Array(shelf.items.prefix(cap))
    }

    private func isPlaylistsShelf(_ shelf: FeedShelf) -> Bool {
        shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playlists"
    }

    private func loadShelves() async {
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

/// Upstream's card representation on the "On device" shelf.
struct OnDeviceCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tintColor: Color
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tintColor.opacity(0.12))
                        .frame(width: 160, height: 160)
                    Image(systemName: systemImage)
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(tintColor)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Dedicated Downloads destination with Songs, Albums, and Artists tabs,
/// matching upstream's unified LocalMusicScreen (isDownloads = true).
struct DownloadsView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var store = DownloadStore.shared
    @State private var selectedTab: Tab = .songs
    @State private var searchQuery: String = ""
    @State private var sort: SortOption = .titleAsc

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case titleAsc = "Title (A–Z)"
        case titleDesc = "Title (Z–A)"
        case artist = "Artist"
        case album = "Album"
        var id: String { rawValue }
    }

    private var localTracks: [LocalTrack] {
        store.items.map { t in
            LocalTrack(
                path: t.path,
                title: t.title,
                artist: t.artist,
                album: t.album,
                durationSeconds: 0,
                artwork: t.artwork,
                dateAdded: nil,
                dateModified: nil
            )
        }
    }

    private var filteredAndSortedTracks: [LocalTrack] {
        var result = localTracks
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                $0.artist.lowercased().contains(q) ||
                $0.album.lowercased().contains(q)
            }
        }
        switch sort {
        case .titleAsc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .artist:
            result.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            result.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        }
        return result
    }

    private var albumGroups: [(name: String, artist: String, tracks: [LocalTrack])] {
        let grouped = Dictionary(grouping: filteredAndSortedTracks) { $0.album.isEmpty ? "Unknown Album" : $0.album }
        return grouped.map { name, tracks in
            (name: name, artist: tracks.first?.artist ?? "Unknown artist", tracks: tracks)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var artistGroups: [(name: String, tracks: [LocalTrack])] {
        let grouped = Dictionary(grouping: filteredAndSortedTracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
        return grouped.map { name, tracks in
            (name: name, tracks: tracks)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "No downloads yet",
                    subtitle: "Save a track from Now Playing — BitChord tags it and keeps it here.",
                    buttonTitle: nil, action: nil
                )
            } else {
                content
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            tabPicker
            toolbar
            switch selectedTab {
            case .songs:
                songsContent
            case .albums:
                albumsContent
            case .artists:
                artistsContent
            }
        }
    }

    private var tabPicker: some View {
        Picker("Category", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter downloads", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    private var playShuffleRow: some View {
        HStack(spacing: 12) {
            Button {
                controller.play(filteredAndSortedTracks.map(QueueEntry.from), at: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                var shuffled = filteredAndSortedTracks.map(QueueEntry.from)
                shuffled.shuffle()
                controller.play(shuffled, at: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private var songsContent: some View {
        VStack(spacing: 0) {
            if !filteredAndSortedTracks.isEmpty {
                playShuffleRow
            }
            List {
                ForEach(Array(filteredAndSortedTracks.enumerated()), id: \.element.id) { index, track in
                    SongRow(
                        entry: QueueEntry.from(track),
                        play: {
                            controller.play(filteredAndSortedTracks.map(QueueEntry.from), at: index)
                        },
                        playNext: { controller.playNext(QueueEntry.from(track)) },
                        addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                }
            }
            .listStyle(.plain)
        }
    }

    private var albumsContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], spacing: 22) {
                ForEach(albumGroups, id: \.name) { group in
                    Button {
                        controller.play(group.tracks.map(QueueEntry.from), at: 0)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(url: nil, data: group.tracks.first?.artwork, side: 160)
                                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            Text(group.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("\(group.artist) • \(group.tracks.count) song\(group.tracks.count == 1 ? "" : "s")")
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
    }

    private var artistsContent: some View {
        List {
            ForEach(artistGroups, id: \.name) { group in
                ArtistGroupRow(group: group)
                    .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
            }
        }
        .listStyle(.plain)
    }
}

/// Dedicated Local Music destination supporting Songs, Albums, and Artists tabs.
struct LocalMusicView: View {
    var initialTab: Tab = .songs
    var onPickFolder: (() -> Void)? = nil
    @Environment(PlaybackController.self) private var controller
    @State private var local = LocalLibrary.shared
    @State private var selectedTab: Tab = .songs
    @State private var pickingFolder = false

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    init(initialTab: Tab = .songs, onPickFolder: (() -> Void)? = nil) {
        self.initialTab = initialTab
        self.onPickFolder = onPickFolder
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        content
            .navigationTitle("Local Music")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        pickFolder()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                    }
                    .buttonStyle(ProfileCircleButtonStyle())
                    .accessibilityLabel("Scan a folder")

                    TopBarAccountButton()
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
            #endif
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    local.scanPicked(url)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if local.scanned {
                    VStack(spacing: 0) {
                        tabPicker
                        if selectedTab == .songs {
                            songsToolbar
                        }
                    }
                    .background(.ultraThinMaterial)
                }
            }
    }

    private var tabPicker: some View {
        Picker("Category", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
    }

    private func pickFolder() {
        if let onPickFolder {
            onPickFolder()
        } else {
            #if os(macOS)
            local.chooseFolder()
            #else
            pickingFolder = true
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { pickFolder() }
        } else if local.tracks.isEmpty {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { pickFolder() }
        } else {
            switch selectedTab {
            case .songs:
                if local.visibleTracks.isEmpty {
                    EmptyStateView(
                        icon: Image(.bchSearch),
                        title: "Nothing matches",
                        subtitle: "No track in this library matches \u{201C}\(local.query)\u{201D}.",
                        buttonTitle: nil, action: nil
                    )
                } else {
                    songsContent
                }
            case .albums:
                albumGrid
            case .artists:
                artistList
            }
        }
    }

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
        VStack(spacing: 0) {
            playShuffleBar
            switch local.viewType {
            case .list:
                List {
                    ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                        SongRow(
                            entry: QueueEntry.from(track),
                            play: {
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
                        ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                            LocalTrackCard(track: track) {
                                let shown = local.visibleTracks
                                controller.play(shown.map(QueueEntry.from), at: index)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var playShuffleBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.play(local.visibleTracks.map(QueueEntry.from), at: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                var shuffled = local.visibleTracks.map(QueueEntry.from)
                shuffled.shuffle()
                controller.play(shuffled, at: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
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
        .navigationTitle("History")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
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
                        ForEach(pinnedShelves(shelves)) { shelf in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(shelf.title).font(.title3.weight(.bold))
                                    Spacer()
                                    if shelf.items.count > 5 {
                                        NavigationLink("Show all") {
                                            LibraryGridView(title: shelf.title, items: shelf.items, isPlaylists: isPlaylistsShelf(shelf))
                                        }
                                        .font(.callout)
                                    }
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        if isPlaylistsShelf(shelf) {
                                            NewPlaylistTile {
                                                appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                                            }
                                        }
                                        ForEach(displayItems(shelf)) { card in
                                            ShelfCardView(card: card)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
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

    /// Upstream's `LIBRARY_ROW_MAX_ITEMS`: a Library row stops at five cards,
    /// with "Show all" opening the rest as a grid. The leading New Playlist
    /// tile counts against the cap.
    private func displayItems(_ shelf: FeedShelf) -> [ShelfCard] {
        let cap = isPlaylistsShelf(shelf) ? 4 : 5
        return Array(shelf.items.prefix(cap))
    }

    private func isPlaylistsShelf(_ shelf: FeedShelf) -> Bool {
        let t = shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "playlists"
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

/// Upstream's `NewShelfCard` on the Library's playlist row: a dashed tile that
/// creates a playlist, sized to sit in line with the covers beside it.
private struct NewPlaylistTile: View {
    var onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.secondary)
                        .frame(width: 160, height: 160)
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                Text("New Playlist")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Saved to YouTube Music")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New playlist")
        .accessibilityHint("Creates a playlist")
    }
}

/// Local Playlists tab: real `.m3u`/`.m3u8` files from the scanned folder,
/// resolved against the scanned tracks, plus the signed-in account's own
/// YouTube playlists. No mock data — an empty folder means an empty list.
private struct LocalPlaylistsView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var local = LocalLibrary.shared
    @State private var files: [LocalM3uPlaylist] = []
    @State private var user: [UserPlaylistDTO] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty && user.isEmpty {
                VStack(spacing: 16) {
                    EmptyStateView(
                        icon: Image(.bchLibrary),
                        title: "No playlists yet",
                        subtitle: auth.signedIn
                            ? "Save a playlist on YouTube Music, or drop an .m3u file in your music folder."
                            : "Drop an .m3u file in your music folder — or sign in for your YouTube playlists.",
                        buttonTitle: auth.signedIn ? "New Playlist" : nil,
                        action: auth.signedIn ? {
                            appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                        } : nil
                    )
                }
            } else {
                List {
                    if !files.isEmpty {
                        Section("On This Device") {
                            ForEach(files) { playlist in
                                NavigationLink {
                                    LocalM3uDetailView(playlist: playlist)
                                } label: {
                                    HStack {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.name).lineLimit(1)
                                            Text("\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "song" : "songs")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !user.isEmpty {
                        Section("YouTube Music") {
                            ForEach(user) { list in
                                NavigationLink {
                                    DetailView(browseId: list.browseId, initialTitle: list.title)
                                } label: {
                                    HStack(spacing: 12) {
                                        ArtworkView(url: list.thumbnailUrl, data: nil, side: 44)
                                            .clipShape(.rect(cornerRadius: 6, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(list.title).lineLimit(1)
                                            if !list.subtitle.isEmpty {
                                                Text(list.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if auth.signedIn {
                    Button {
                        appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                    }
                    .buttonStyle(ProfileCircleButtonStyle())
                    .accessibilityLabel("New Playlist")
                }

                TopBarAccountButton()
            }
        }
        #endif
        .task(id: auth.sessionEpoch) { await load() }
        .onAppear { local.restoreViewPreferences() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        files = Self.localM3uPlaylists(tracks: local.tracks)
        if auth.signedIn {
            user = await LibraryActions.userPlaylists()
        } else {
            user = []
        }
        loading = false
    }

    /// Reads `.m3u`/`.m3u8` files from the scanned folder and resolves their
    /// entries against the scanned tracks by absolute path, then by filename.
    static func localM3uPlaylists(tracks: [LocalTrack]) -> [LocalM3uPlaylist] {
        guard let folder = Self.libraryFolder() else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let m3uURLs = enumerator.compactMap { $0 as? URL }.filter {
            ["m3u", "m3u8"].contains($0.pathExtension.lowercased())
        }
        let byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(
            tracks.map { (URL(fileURLWithPath: $0.path).lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return m3uURLs.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let base = url.deletingLastPathComponent()
            var resolved: [LocalTrack] = []
            for line in text.components(separatedBy: .newlines) {
                let entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
                let candidate: URL = entry.hasPrefix("/")
                    ? URL(fileURLWithPath: entry)
                    : base.appendingPathComponent(entry)
                let standardized = candidate.standardized.path
                if let track = byPath[standardized] ?? byPath[candidate.path] {
                    resolved.append(track)
                } else if let track = byName[candidate.lastPathComponent.lowercased()] {
                    resolved.append(track)
                }
            }
            guard !resolved.isEmpty else { return nil }
            return LocalM3uPlaylist(
                id: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                tracks: resolved
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The scanned folder, resolved from the persisted bookmark — the same
    /// bookmark `LocalLibrary` restores, read here because the store does not
    /// expose the folder itself.
    static func libraryFolder() -> URL? {
        let stored = PlatformSettings.shared.getString(key: "local_library_path", default: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }
}

private struct LocalM3uPlaylist: Identifiable {
    let id: String
    let name: String
    let tracks: [LocalTrack]
}

/// The tracks of one local `.m3u` playlist.
private struct LocalM3uDetailView: View {
    let playlist: LocalM3uPlaylist
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                SongRow(
                    entry: QueueEntry.from(track),
                    play: {
                        controller.play(playlist.tracks.map(QueueEntry.from), at: index)
                    },
                    playNext: { controller.playNext(QueueEntry.from(track)) },
                    addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
    }
}

struct LibraryGridView: View {
    let title: String
    let items: [ShelfCard]
    var isPlaylists: Bool = false

    @Environment(AppModel.self) private var appModel
    @State private var searchQuery = ""
    @State private var sortOrder: SortOrder = .defaultOrder

    enum SortOrder: String, CaseIterable, Identifiable {
        case defaultOrder = "Default"
        case titleAsc = "Title (A–Z)"
        case titleDesc = "Title (Z–A)"
        var id: String { rawValue }
    }

    private var sortedAndFilteredItems: [ShelfCard] {
        var result = items
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) == true)
            }
        }
        switch sortOrder {
        case .defaultOrder:
            let pinned = PlaylistPinning.pinnedIds()
            if isPlaylists, !pinned.isEmpty {
                result.sort { a, b in
                    let ap = pinned.contains(a.browseId ?? "")
                    let bp = pinned.contains(b.browseId ?? "")
                    if ap == bp { return false }
                    return ap && !bp
                }
            }
        case .titleAsc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                if isPlaylists {
                    NewPlaylistTile {
                        appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                    }
                }
                ForEach(sortedAndFilteredItems) { card in
                    ShelfCardView(card: card)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchQuery, prompt: "Filter \(title)")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                }
                .buttonStyle(ProfileCircleButtonStyle())
                .accessibilityLabel("Sort \(title)")

                TopBarAccountButton()
            }
        }
        #else
        .searchable(text: $searchQuery, prompt: "Filter \(title)")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        #endif
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

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
                    // Upstream FrostedTopBar's root-page leading BitChord logo.
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
        // "Recents" so the feed keeps the four-row treatment.
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
    @Environment(AuthController.self) private var auth
    @Environment(\.horizontalSizeClass) private var sizeClass

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
                .task(id: auth.sessionEpoch) {
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
                LazyVGrid(columns: moodColumns, spacing: 14) {
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
                    LazyVGrid(columns: moodColumns, spacing: 14) {
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

    /// Two across on iPhone like upstream's `MoodGenreGrid`; adaptive on iPad and Mac
    /// where wide windows comfortably host 4 to 6 categories across.
    private var moodColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        #else
        if sizeClass == .regular {
            return [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        } else {
            return [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
            ]
        }
        #endif
    }
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
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
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
                .refreshable { await load(force: true) }
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
        .task(id: auth.sessionEpoch) { shelves = []; phase = .loading; await load() }
    }

    private func load(force: Bool = false) async {
        let generation = PageSession.generation()
        if shelves.isEmpty { phase = .loading }
        do {
            let result = try await InnertubeFeed.shared.moodGenreShelves(
                browseId: category.browseId, params: category.params, force: force
            )
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
            phase = .loaded
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            if !shelves.isEmpty { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Loads the mood/genre categories, and their tile artwork afterwards.
///
/// The two-step shape is upstream's and it is deliberate: the grid is worth
/// painting before it is worth labelling with pictures, and the artwork comes
/// from each category's page. Simultaneous requests share the network work;
/// completed page data is not retained.
@MainActor @Observable
final class MoodGenreLoader {
    enum Phase { case loading, loaded([MoodGenreSection]), failed(String) }

    private(set) var phase: Phase = .loading
    private var loadedGeneration: Int64?
    private var requestID = UUID()

    func load(force: Bool) async {
        let generation = PageSession.generation()
        let id = UUID(); requestID = id
        if loadedGeneration != generation { phase = .loading }
        loadedGeneration = generation
        do {
            var sections = try await InnertubeFeed.shared.moodAndGenres(force: force)
            guard generation == PageSession.generation(), requestID == id, !Task.isCancelled else { return }
            phase = .loaded(sections)
            await fillArtwork(&sections, generation: generation, id: id)
        } catch {
            guard generation == PageSession.generation(), requestID == id, !Task.isCancelled else { return }
            if case .loaded = phase { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Replaces the categories with ones carrying artwork, once each has
    /// answered. Published one section at a time so the first covers to arrive
    /// are on screen while the rest are still being asked for.
    private func fillArtwork(_ sections: inout [MoodGenreSection], generation: Int64, id: UUID) async {
        // Start in display order and cap concurrency: visible tiles go first.
        let jobs = sections.indices.flatMap { section in
            sections[section].items.indices.compactMap { item -> (Int, Int, MoodGenre)? in
                let category = sections[section].items[item]
                return category.thumbnailUrl == nil ? (section, item, category) : nil
            }
        }
        await withTaskGroup(of: (Int, Int, String?).self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]; next += 1
                group.addTask {
                    let cover = await InnertubeFeed.shared.moodGenreArtwork(browseId: job.2.browseId, params: job.2.params)
                    return (job.0, job.1, cover)
                }
            }
            for _ in 0..<min(4, jobs.count) { enqueue() }
            while let (section, item, cover) = await group.next() {
                guard generation == PageSession.generation(), requestID == id, !Task.isCancelled else {
                    group.cancelAll(); return
                }
                if let cover { sections[section].items[item].thumbnailUrl = cover; publish(sections) }
                enqueue()
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
    /// When set (sidebar `TabSection` rows on macOS and iPad), this destination
    /// is shown directly. The section page owns its navigation title and
    /// toolbar — nothing outer may add its own, or the two sets merge.
    var lockedSection: Section? = nil

    enum Section: String, CaseIterable, Identifiable {
        case youtube, songs, albums, artists, playlists, subscriptions, podcasts, ondevice, downloads, history, webdav
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: "Recent"
            case .webdav: "WebDAV"
            case .ondevice: "On Device"
            default: rawValue.capitalized
            }
        }
    }

    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            if let locked = lockedSection {
                // One header only. The section page below owns its title and
                // trailing buttons; an outer `.navigationTitle`/`.toolbar`
                // here would merge with the inner set — two scan-folder
                // pluses and two profile discs side by side, with the outer
                // title ("Songs") fighting the inner one ("Local Music").
                lockedContent(locked)
            } else {
                LibraryLandingView(onPickFolder: { pickFolder() })
                .navigationTitle("Library")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarLeadingMark()
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // One shared pill for the action buttons — not a glass
                        // disc each. (The account disc beside it stays solo,
                        // like on every other tab.)
                        HStack(spacing: 2) {
                            NavigationLink {
                                HistoryView()
                            } label: {
                                Image(systemName: "clock")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, height: 34)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ProfileCircleButtonStyle())
                            .accessibilityLabel("Listening History")

                            Divider()
                                .frame(height: 20)
                                .opacity(0.5)

                            Button {
                                pickFolder()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, height: 34)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ProfileCircleButtonStyle())
                            .accessibilityLabel("Scan a folder")
                        }
                        .padding(.horizontal, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))

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
            }
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

    @ViewBuilder
    private func lockedContent(_ locked: Section) -> some View {
        switch locked {
        case .youtube: YoutubeLibraryView()
        case .songs: UnifiedSongsView(title: locked.label, onPickFolder: { pickFolder() })
        case .albums: UnifiedAlbumsView(title: locked.label, onPickFolder: { pickFolder() })
        case .artists: UnifiedArtistsView(title: locked.label, onPickFolder: { pickFolder() })
        case .playlists: SavedPlaylistsView()
        case .subscriptions: SavedShelfView(shelfName: "Subscriptions", title: "Subscriptions", emptySubtitle: "Channels you subscribe to show up here.")
        case .podcasts: SavedShelfView(shelfName: "Podcasts", title: "Podcasts", emptySubtitle: "Podcasts you follow show up here.")
        case .ondevice: OnDeviceView()
        case .downloads: DownloadsView()
        case .webdav: WebDavLibraryView()
        case .history: HistoryView()
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
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // 1. Replay hero: cards when there is listening data, banner before.
                ReplayHeroSection { page in appModel.openReplay(at: page) }

                // 2. On Device Shelf
                onDeviceShelf

                // 3. Signed-out prompt or Signed-in shelves
                if !auth.signedIn {
                    signedInPrompt
                } else if loading {
                    FeedSkeleton()
                } else if let error, shelves.isEmpty {
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
            await loadShelves(force: true)
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

    private func loadShelves(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
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
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
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
                controller.togglePlaybackContext(filteredAndSortedTracks.map(QueueEntry.from), title: "Downloads", contextID: "downloads:songs")
            } label: {
                Label(controller.isPlaybackContextPlaying("downloads:songs") ? "Pause" : "Play",
                      systemImage: controller.isPlaybackContextPlaying("downloads:songs") ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                controller.play(filteredAndSortedTracks.map(QueueEntry.from), context: "Downloads", contextID: "downloads:songs", shuffleRequested: true, shuffleStart: true)
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
                            controller.play(filteredAndSortedTracks.map(QueueEntry.from), at: index, context: "Downloads", contextID: "downloads:songs")
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
                        controller.play(group.tracks.map(QueueEntry.from), context: group.name, contextID: "local-album:\(group.artist):\(group.name)")
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

/// The scanned-folder library with its in-page Songs/Albums/Artists picker.
///
/// This is the iPhone drill-down behind the On Device card. The sidebar's
/// Songs/Albums/Artists rows are NOT this screen: they are unified pages
/// (saved cloud collections + this device's files) built from the same
/// section pieces below.
struct LocalMusicView: View {
    var initialTab: Tab = .songs
    /// Navigation title. The sidebar row's name when opened from it
    /// ("Songs"/"Albums"/"Artists"); "Local Music" on the iPhone drill-down.
    var title: String = "Local Music"
    var onPickFolder: (() -> Void)? = nil
    @State private var local = LocalLibrary.shared
    @State private var selectedTab: Tab = .songs
    @State private var pickingFolder = false

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    init(initialTab: Tab = .songs, title: String = "Local Music", onPickFolder: (() -> Void)? = nil) {
        self.initialTab = initialTab
        self.title = title
        self.onPickFolder = onPickFolder
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarLeadingMark()
                }
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
                    tabPicker
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
        switch selectedTab {
        case .songs:
            LocalSongsBrowser(onPickFolder: pickFolder)
        case .albums:
            LocalAlbumGrid(onPickFolder: pickFolder)
        case .artists:
            LocalArtistList(onPickFolder: pickFolder)
        }
    }
}

/// The Songs half of the scanned-folder library: filter, sort, Play/Shuffle,
/// list/grid. Shared by the Local Music page and the unified Songs row.
struct LocalSongsBrowser: View {
    var onPickFolder: () -> Void
    @Environment(PlaybackController.self) private var controller
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.tracks.isEmpty {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { onPickFolder() }
        } else {
            VStack(spacing: 0) {
                songsToolbar
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
            }
        }
    }

    private var songsToolbar: some View {
        HStack(spacing: 10) {
            SongFilterControls(local: local)

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
                                controller.play(shown.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
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
                                controller.play(shown.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
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
                controller.togglePlaybackContext(local.visibleTracks.map(QueueEntry.from), title: "On Device", contextID: "local:songs")
            } label: {
                Label(controller.isPlaybackContextPlaying("local:songs") ? "Pause" : "Play",
                      systemImage: controller.isPlaybackContextPlaying("local:songs") ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button {
                controller.play(local.visibleTracks.map(QueueEntry.from), context: "On Device", contextID: "local:songs", shuffleRequested: true, shuffleStart: true)
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
}

/// Filter capsule + sort menu for song lists, without the list/grid toggle.
/// Shared by the full browser and the unified Songs row's device section.
struct SongFilterControls: View {
    @Bindable var local: LocalLibrary

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter this library", text: $local.query)
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
                Picker("Sort By", selection: $local.sort) {
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
        }
    }
}

/// The Albums half of the scanned-folder library. Shared by the Local Music
/// page and the unified Albums row's On This Device section.
struct LocalAlbumGrid: View {
    var onPickFolder: () -> Void
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.albumGroups.isEmpty {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No albums yet",
                subtitle: "Albums group themselves once a folder with tagged music is scanned.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                    ForEach(local.albumGroups, id: \.name) { group in
                        LocalAlbumCell(group: group)
                    }
                }
                .padding(20)
            }
        }
    }
}

/// One scanned-folder album: sleeve, name, artist. Tapping plays the album.
struct LocalAlbumCell: View {
    let group: (name: String, artist: String, tracks: [LocalTrack])
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        Button {
            controller.play(group.tracks.map(QueueEntry.from), context: group.name, contextID: "local-album:\(group.artist):\(group.name)")
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

/// The Artists half of the scanned-folder library. Shared by the Local Music
/// page and the unified Artists row's On This Device section.
struct LocalArtistList: View {
    var onPickFolder: () -> Void
    @State private var local = LocalLibrary.shared

    @ViewBuilder
    var body: some View {
        if !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Scan your music",
                subtitle: "Pick a folder — BitChord reads its tags, artwork and plays it with gapless and crossfade.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
        } else if local.artistGroups.isEmpty {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No artists yet",
                subtitle: "Artists group themselves once a folder with tagged music is scanned.",
                buttonTitle: "Choose Folder"
            ) { onPickFolder() }
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

/// A saved-collections grid straight from one signed-in library shelf
/// (Subscriptions, Podcasts). Cards navigate to their detail pages like
/// every other shelf grid.
struct SavedShelfView: View {
    var shelfName = "Subscriptions"
    var title = "Subscriptions"
    var emptySubtitle = "Channels you subscribe to show up here."
    @Environment(AuthController.self) private var auth
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var items: [ShelfCard] {
        libraryShelf(titled: shelfName, in: shelves)?.items ?? []
    }

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Sign in for your library",
                    subtitle: emptySubtitle,
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ScrollView { FeedSkeleton() }
            } else if let error, items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "\(title) couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Nothing here yet",
                    subtitle: emptySubtitle,
                    buttonTitle: nil, action: nil
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                        ForEach(items) { card in
                            ShelfCardView(card: card)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The Playlists row: the signed-in Playlists shelf with the New Playlist
/// tile leading, like the library landing's playlist row but full-page.
struct SavedPlaylistsView: View {
    var title = "Playlists"
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var items: [ShelfCard] {
        libraryShelf(titled: "playlists", in: shelves)?.items ?? []
    }

    var body: some View {
        Group {
            if !auth.signedIn {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Sign in for your playlists",
                    subtitle: "Playlists you save show up here.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else if loading {
                ScrollView { FeedSkeleton() }
            } else if let error, items.isEmpty {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Playlists couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                        NewPlaylistTile {
                            appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                        }
                        ForEach(items) { card in
                            ShelfCardView(card: card)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The On Device row: everything that lives on this hardware — downloads,
/// the scanned folder, the remote share — the destinations upstream's
/// On Device shelf cards open.
struct OnDeviceView: View {
    var title = "On Device"
    @State private var downloadStore = DownloadStore.shared
    @State private var local = LocalLibrary.shared

    var body: some View {
        List {
            NavigationLink(destination: DownloadsView()) {
                deviceRow(
                    systemImage: "arrow.down.circle.fill", tint: .accentColor,
                    title: "Downloads",
                    subtitle: "\(downloadStore.items.count) downloaded song\(downloadStore.items.count == 1 ? "" : "s")"
                )
            }
            NavigationLink(destination: LocalMusicView()) {
                deviceRow(
                    systemImage: "folder.fill", tint: .indigo,
                    title: "Local Music",
                    subtitle: local.scanned ? "\(local.tracks.count) song\(local.tracks.count == 1 ? "" : "s")" : "Choose a folder to scan"
                )
            }
            NavigationLink(destination: WebDavLibraryView()) {
                deviceRow(
                    systemImage: "cloud.fill", tint: .teal,
                    title: "WebDAV",
                    subtitle: WebDavStore.shared.isConfigured ? "Connected" : "Not configured"
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .onAppear {
            downloadStore.refresh()
            local.restoreViewPreferences()
        }
    }

    private func deviceRow(systemImage: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 12))
    }
}

/// The signed-in library shelf coined under this title by the shared bridge
/// (`LibraryBridge` fetches Playlists/Albums/Artists/Subscriptions in
/// parallel). Titles are matched case-insensitively like the Playlists shelf.
private func libraryShelf(titled name: String, in shelves: [FeedShelf]) -> FeedShelf? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return shelves.first {
        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
    }
}

/// The Songs row: liked tracks from the signed-in library on top, this
/// device's scanned songs below. Either half alone is a complete page, so
/// the row is never the empty "choose a folder" wall it used to be.
struct UnifiedSongsView: View {
    var title = "Songs"
    var onPickFolder: (() -> Void)? = nil
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @State private var local = LocalLibrary.shared
    @State private var pickingFolder = false
    @State private var songs: [YouTubeSong] = []
    @State private var dataGeneration: Int64?
    @State private var songsLoading = true
    @State private var songsError: String?

    private var cloudEntries: [QueueEntry] { songs.map(songEntry) }

    private func songEntry(_ song: YouTubeSong) -> QueueEntry {
        QueueEntry(
            id: song.videoId, title: song.title, artist: song.artist,
            source: "yt:\(song.videoId)", thumbnailUrl: song.thumbnailUrl,
            durationText: song.durationText, albumName: song.albumName,
            artworkData: nil, isLocal: false
        )
    }

    var body: some View {
        Group {
            if !auth.signedIn && !local.scanned {
                EmptyStateView(
                    icon: Image(.bchMusicNote),
                    title: "Your songs live here",
                    subtitle: "Songs you add to your YouTube Music library — or a folder you scan on this device.",
                    buttonTitle: "Sign In"
                ) { auth.loginPresented = true }
            } else {
                List {
                    if auth.signedIn {
                        Section("Your Songs") {
                            if songsLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .listRowSeparator(.hidden)
                            } else if let songsError, songs.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(songsError)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Button("Try again") {
                                        Task { await loadSongs() }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                                }
                            } else if songs.isEmpty {
                                Text("Songs you add to your library show up here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                    SongRow(
                                        entry: songEntry(song),
                                        play: { controller.play(cloudEntries, at: index, context: title, contextID: "library:songs") },
                                        playNext: { controller.playNext(songEntry(song)) },
                                        addToQueue: { controller.addToQueue(songEntry(song)) }
                                    )
                                }
                            }
                        }
                    }
                    Section("On This Device") {
                        if !local.scanned {
                            Button {
                                pickFolder()
                            } label: {
                                HStack {
                                    Text("Scan a folder to see its songs here too.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            SongFilterControls(local: local)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                            if local.visibleTracks.isEmpty {
                                Text(local.tracks.isEmpty ? "No audio files in the scanned folder." : "Nothing matches the current filter.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(local.visibleTracks.enumerated()), id: \.element.id) { index, track in
                                    SongRow(
                                        entry: QueueEntry.from(track),
                                        play: {
                                            controller.play(local.visibleTracks.map(QueueEntry.from), at: index, context: "On Device", contextID: "local:songs")
                                        },
                                        playNext: { controller.playNext(QueueEntry.from(track)) },
                                        addToQueue: { controller.addToQueue(QueueEntry.from(track)) }
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
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
        .task(id: auth.sessionEpoch) { await loadSongs() }
    }

    private func loadSongs(force: Bool = false) async {
        guard auth.signedIn else {
            songsLoading = false
            songs = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { songs = []; dataGeneration = generation }
        songsLoading = songs.isEmpty
        songsError = nil
        do {
            let result = try await InnertubeFeed.shared.librarySongs(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            songs = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.songsError = error.localizedDescription
        }
        songsLoading = false
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
}

/// The Albums row: saved albums from the signed-in library, then this
/// device's scanned albums. Same contract as Songs: each half stands alone.
struct UnifiedAlbumsView: View {
    var title = "Albums"
    var onPickFolder: (() -> Void)? = nil
    @Environment(AuthController.self) private var auth
    @State private var local = LocalLibrary.shared
    @State private var pickingFolder = false
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var saved: [ShelfCard] {
        libraryShelf(titled: "albums", in: shelves)?.items ?? []
    }

    private var hasCloud: Bool { !saved.isEmpty }
    private var hasDevice: Bool { local.scanned && !local.albumGroups.isEmpty }

    var body: some View {
        Group {
            if auth.signedIn && loading {
                ScrollView { FeedSkeleton() }
            } else if let error, !hasDevice {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Albums couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if !hasCloud && !hasDevice {
                combinedEmpty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if hasCloud {
                            collectionSection(title: "Saved Albums", items: saved)
                        }
                        if local.scanned {
                            if hasDevice {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("On This Device")
                                        .font(.title3.weight(.bold))
                                        .padding(.horizontal, 24)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                                        ForEach(local.albumGroups, id: \.name) { group in
                                            LocalAlbumCell(group: group)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                            } else {
                                Text("No albums in the scanned folder.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                            }
                        } else if hasCloud {
                            scanPrompt(kind: "albums")
                        }
                    }
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
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
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func collectionSection(title: String, items: [ShelfCard]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 24)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                ForEach(items) { card in
                    ShelfCardView(card: card)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func scanPrompt(kind: String) -> some View {
        Button {
            pickFolder()
        } label: {
            HStack(spacing: 12) {
                Image(.bchLibrary)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Device")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Scan a folder to see its \(kind) here too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var combinedEmpty: some View {
        if !auth.signedIn && !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Your albums live here",
                subtitle: "Save albums on YouTube Music — or scan a folder on this device.",
                buttonTitle: "Sign In"
            ) { auth.loginPresented = true }
        } else if local.scanned {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { pickFolder() }
        } else {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No saved albums yet",
                subtitle: "Albums you save on YouTube Music show up here — or scan a folder on this device.",
                buttonTitle: "Choose Folder"
            ) { pickFolder() }
        }
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

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The Artists row: saved artists from the signed-in library, then this
/// device's scanned artists. Same contract as Songs and Albums.
struct UnifiedArtistsView: View {
    var title = "Artists"
    var onPickFolder: (() -> Void)? = nil
    @Environment(AuthController.self) private var auth
    @State private var local = LocalLibrary.shared
    @State private var pickingFolder = false
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
    @State private var loading = true
    @State private var error: String?

    private var saved: [ShelfCard] {
        libraryShelf(titled: "artists", in: shelves)?.items ?? []
    }

    private var hasCloud: Bool { !saved.isEmpty }
    private var hasDevice: Bool { local.scanned && !local.artistGroups.isEmpty }

    var body: some View {
        Group {
            if auth.signedIn && loading {
                ScrollView { FeedSkeleton() }
            } else if let error, !hasDevice {
                EmptyStateView(
                    icon: Image(.bchLibrary),
                    title: "Artists couldn't load",
                    subtitle: error,
                    buttonTitle: "Retry"
                ) { Task { await load() } }
            } else if !hasCloud && !hasDevice {
                combinedEmpty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if hasCloud {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Saved Artists")
                                    .font(.title3.weight(.bold))
                                    .padding(.horizontal, 24)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 20) {
                                    ForEach(saved) { card in
                                        ShelfCardView(card: card)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                        if local.scanned {
                            if hasDevice {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("On This Device")
                                        .font(.title3.weight(.bold))
                                        .padding(.horizontal, 24)
                                    LazyVStack(spacing: 2) {
                                        ForEach(local.artistGroups, id: \.name) { group in
                                            ArtistGroupRow(group: group)
                                                .padding(.horizontal, 24)
                                        }
                                    }
                                }
                            } else {
                                Text("No artists in the scanned folder.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                            }
                        } else if hasCloud {
                            scanPrompt(kind: "artists")
                        }
                    }
                    .padding(.vertical, 20)
                }
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
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
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func scanPrompt(kind: String) -> some View {
        Button {
            pickFolder()
        } label: {
            HStack(spacing: 12) {
                Image(.bchLibrary)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Device")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Scan a folder to see its \(kind) here too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var combinedEmpty: some View {
        if !auth.signedIn && !local.scanned {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Your artists live here",
                subtitle: "Follow artists on YouTube Music — or scan a folder on this device.",
                buttonTitle: "Sign In"
            ) { auth.loginPresented = true }
        } else if local.scanned {
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "No audio files here",
                subtitle: "The folder you selected didn't contain any supported audio files.",
                buttonTitle: "Choose Another Folder"
            ) { pickFolder() }
        } else {
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No saved artists yet",
                subtitle: "Artists you follow on YouTube Music show up here — or scan a folder on this device.",
                buttonTitle: "Choose Folder"
            ) { pickFolder() }
        }
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

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
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
                        play: { controller.play(group.tracks.map(QueueEntry.from), at: index, context: group.name, contextID: "local-artist:\(group.name)") }
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
    @State private var dataGeneration: Int64?
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
            } else if let error, songs.isEmpty {
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
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
        .task(id: auth.sessionEpoch) { await load() }
    }

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            songs = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { songs = []; dataGeneration = generation }
        loading = songs.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.history(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            songs = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Signed-in YouTube Music library: playlists, albums, artists.
///
/// Upstream's `library()` feed — the same shelves `LibraryLandingView` shows
/// signed-in users on iPhone. The sidebar's Recent row is this feed as a
/// destination (it owns its title and toolbar like every other locked
/// section, since the hosting `LibraryView` adds no outer chrome).
private struct YoutubeLibraryView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var shelves: [FeedShelf] = []
    @State private var dataGeneration: Int64?
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
            } else if let error, shelves.isEmpty {
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
                        ReplayHeroSection { page in appModel.openReplay(at: page) }
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
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle("Recent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItem(placement: .topBarTrailing) {
                TopBarAccountButton()
            }
        }
        #endif
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

    private func load(force: Bool = false) async {
        guard auth.signedIn else {
            loading = false
            shelves = []
            return
        }
        let generation = PageSession.generation()
        if dataGeneration != generation { shelves = []; dataGeneration = generation }
        loading = shelves.isEmpty
        error = nil
        do {
            let result = try await InnertubeFeed.shared.library(force: force)
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
            shelves = result
        } catch {
            guard generation == PageSession.generation(), !Task.isCancelled else { return }
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
    @State private var imported = ImportedPlaylistStore.shared
    @State private var showImportPicker = false
    @State private var importDraft: PlaylistImportDraft?
    @State private var matchingImport = false
    @State private var showImportMessage = false
    @State private var importMessage = ""

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty && user.isEmpty && imported.playlists.isEmpty {
                VStack(spacing: 16) {
                    EmptyStateView(
                        icon: Image(.bchLibrary),
                        title: "No playlists yet",
                        subtitle: auth.signedIn
                            ? "Import a CSV or TSV playlist export from Spotify or Apple Music, save a playlist on YouTube Music, or drop an .m3u file in your music folder."
                            : "Import a CSV or TSV playlist export from Spotify or Apple Music, or drop an .m3u file in your music folder.",
                        buttonTitle: nil,
                        action: nil
                    )
                    Button("Import Playlist File", systemImage: "square.and.arrow.down") {
                        showImportPicker = true
                    }
                    .buttonStyle(.bordered)
                    if auth.signedIn {
                        Button("New YouTube Music Playlist", systemImage: "plus") {
                            appModel.playlistPicker = PlaylistPickerRequest(videoId: "", title: "")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                List {
                    if !imported.playlists.isEmpty {
                        Section("Imported to BitChord") {
                            ForEach(imported.playlists) { playlist in
                                NavigationLink {
                                    ImportedPlaylistDetailView(playlist: playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.title).lineLimit(1)
                                            Text("\(playlist.matchedCount) of \(playlist.tracks.count) tracks · \(playlist.sourceName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        imported.remove(playlist)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Import Playlist File", systemImage: "square.and.arrow.down") {
                            showImportPicker = true
                        }
                    }
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
            ToolbarItem(placement: .topBarLeading) {
                TopBarLeadingMark()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                }
                .buttonStyle(ProfileCircleButtonStyle())
                .accessibilityLabel("Import Playlist File")

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
        .refreshable { await load(force: true) }
        .overlay {
            if matchingImport {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Matching playlist tracks…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(result)
        }
        .sheet(item: $importDraft) { draft in
            PlaylistImportReviewView(draft: draft) { error in
                importMessage = error ?? "Playlist saved to BitChord. Reimporting this file will update the same playlist."
                showImportMessage = true
            }
        }
        .alert("Playlist Import", isPresented: $showImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }

    private func load(force: Bool = false) async {
        loading = true
        files = Self.localM3uPlaylists(tracks: local.tracks)
        if auth.signedIn {
            user = await LibraryActions.userPlaylists()
        } else {
            user = []
        }
        loading = false
    }

    private func prepareImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
            showImportMessage = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try PlaylistFileImport.parse(data: Data(contentsOf: url), filename: url.lastPathComponent)
                Task {
                    matchingImport = true
                    defer { matchingImport = false }
                    let matched = await PlaylistFileImport.match(parsed)
                    importDraft = matched
                }
            } catch {
                importMessage = error.localizedDescription
                showImportMessage = true
            }
        }
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
                        controller.play(playlist.tracks.map(QueueEntry.from), at: index, context: playlist.name, contextID: "m3u:\(playlist.id)")
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

import SwiftUI
import BitChordShared

enum ReplayStoryPage: Int, CaseIterable, Identifiable {
    case intro, minutes, artists, songs, albums, genres, habits, summary
    var id: Int { rawValue }
}

struct ReplayHeroCard: Identifiable {
    var label: String
    var value: String
    var detail: String?
    var artwork: String?
    var page: ReplayStoryPage
    var id: String { label }
}

/// Replay numbers for one `ListeningPeriod` — songs, artists, albums, genres,
/// minutes, and stories all come from `ListeningStore.summary(period:)`.
struct ReplayModel {
    var period: ListeningPeriod
    var summary: ReplaySummary
    var memberSince: String?
    var holder: String

    var cards: [ReplayHeroCard] {
        var list: [ReplayHeroCard] = [
            ReplayHeroCard(
                label: "Minutes listened",
                value: Self.grouped(summary.minutes),
                detail: "\(summary.totalPlays) plays · \(summary.label)",
                artwork: summary.songs.first?.art,
                page: .minutes
            )
        ]
        if let artist = summary.artists.first {
            list.append(ReplayHeroCard(
                label: "Top artist",
                value: artist.name,
                detail: "\(Self.formatListening(artist.ms)) · \(artist.plays) plays",
                artwork: summary.songs.first { $0.artist == artist.name }?.art,
                page: .artists
            ))
        }
        if let song = summary.songs.first {
            list.append(ReplayHeroCard(
                label: "Top song",
                value: song.title,
                detail: "\(song.artist) · \(song.plays) plays",
                artwork: song.art,
                page: .songs
            ))
        }
        if let album = summary.albums.first {
            list.append(ReplayHeroCard(
                label: "Top album",
                value: album.name,
                detail: "\(Self.formatListening(album.ms)) · \(album.plays) plays",
                artwork: summary.songs.first { $0.album == album.name }?.art,
                page: .albums
            ))
        }
        return list
    }

    static func load(period: ListeningPeriod, holder: String) -> ReplayModel {
        let includeGenres = PlatformSettings.shared.getBoolean(key: "replay_genres", default: true)
        let summary = ListeningStore.shared.summary(period: period, includeGenres: includeGenres)
        return ReplayModel(
            period: period,
            summary: summary,
            memberSince: formatSince(summary.since),
            holder: holder
        )
    }

    private static func formatSince(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "-")
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return raw }
        return String(format: "%02d/%02d", m, y % 100)
    }

    static func formatListening(_ ms: Double) -> String {
        let minutes = Int(ms / 60_000)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 1_440 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return "\(grouped(minutes)) min"
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct ReplayView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth
    @State private var period: ListeningPeriod = .thisYear
    @State private var model = ReplayModel.load(period: .thisYear, holder: "")
    @State private var storyPage: ReplayStoryPage?
    @State private var shareItem: ReplayShareItem?

    var body: some View {
        NavigationStack {
            Group {
                if model.summary.isEmpty {
                    EmptyStateView(
                        icon: Image(.bchClock),
                        title: "Your Replay is growing",
                        subtitle: emptyCopy,
                        buttonTitle: nil, action: nil
                    )
                } else {
                    replayPage
                }
            }
            .navigationTitle("Replay")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { appModel.replayPresented = false }
                }
                if !model.summary.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            shareItem = ReplayShareItem(model: model, page: nil)
                        }
                    }
                }
            }
            .onAppear { reload() }
            .onChange(of: period) { _, _ in reload() }
            .modifier(ReplayStoriesPresentation(
                storyPage: $storyPage,
                shareItem: $shareItem,
                model: model
            ))
            .sheet(item: $shareItem) { item in
                ReplayShareSheet(item: item)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var emptyCopy: String {
        switch period {
        case .thisMonth: "There isn't much from this month yet. Play a few songs and it will fill in."
        case .thisYear: "Play a few songs this year and this page will fill in with minutes, top tracks and artists."
        case .allTime: "Play a few songs and this page will fill in with minutes, top tracks and artists."
        }
    }

    private var replayPage: some View {
        ZStack {
            MeshBackdrop(seed: model.summary.songs.first?.title.hashValue ?? 0)
                .ignoresSafeArea()
            LinearGradient(
                colors: [.black.opacity(0.30), .black.opacity(0.72), .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Replay")
                            .font(.largeTitle.weight(.heavy))
                            .foregroundStyle(.white)
                        Text(model.summary.label)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                        periodPicker
                    }
                    .padding(.horizontal, 24)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.cards) { card in
                                ReplayCreditCardView(
                                    card: card,
                                    holder: model.holder,
                                    memberSince: model.memberSince
                                ) {
                                    storyPage = card.page
                                }
                                .frame(width: 300)
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    Button {
                        storyPage = .intro
                    } label: {
                        actionRow(system: "play.fill", title: "Play your Replay")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)

                    chart("Top songs", rows: model.summary.songs.prefix(10).map {
                        ReplayChartRow(id: $0.id, rank: 0, title: $0.title, subtitle: $0.artist, art: $0.art, ms: $0.ms)
                    }) { row in
                        if let song = model.summary.songs.first(where: { $0.id == row.id }) {
                            controller.play([
                                QueueEntry.youtube(
                                    videoId: song.id, title: song.title, artist: song.artist,
                                    thumbnailUrl: song.art, albumName: song.album,
                                    artistId: song.artistId, albumId: song.albumId
                                )
                            ], at: 0)
                        }
                    }
                    chart("Top artists", rows: model.summary.artists.prefix(10).enumerated().map {
                        ReplayChartRow(
                            id: $0.element.id, rank: $0.offset, title: $0.element.name,
                            subtitle: $0.element.sub, art: $0.element.art, ms: $0.element.ms
                        )
                    }, circular: true) { row in
                        if let artist = model.summary.artists.first(where: { $0.id == row.id }), let id = artist.browseId {
                            appModel.pendingDetail = .detail(browseId: id, title: artist.name)
                        }
                    }
                    chart("Top albums", rows: model.summary.albums.prefix(10).enumerated().map {
                        ReplayChartRow(
                            id: $0.element.id, rank: $0.offset, title: $0.element.name,
                            subtitle: $0.element.sub, art: $0.element.art, ms: $0.element.ms
                        )
                    }) { row in
                        if let album = model.summary.albums.first(where: { $0.id == row.id }), let id = album.browseId {
                            appModel.pendingDetail = .detail(browseId: id, title: album.name)
                        }
                    }
                    if !model.summary.genres.isEmpty {
                        chart("Top genres", rows: model.summary.genres.prefix(10).enumerated().map {
                            ReplayChartRow(
                                id: $0.element.id, rank: $0.offset, title: $0.element.name,
                                subtitle: nil, art: nil, ms: $0.element.ms
                            )
                        }) { _ in }
                    }

                    if let day = model.summary.busiestDay {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Biggest day")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text("\(day) · \(Int(model.summary.busiestDayMs / 60_000)) min")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 24)
                    }

                    Button {
                        shareItem = ReplayShareItem(model: model, page: nil)
                    } label: {
                        actionRow(system: "square.and.arrow.up", title: "Share my Replay")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
                .padding(.top, 12)
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach([ListeningPeriod.thisYear, .allTime, .thisMonth]) { item in
                Button {
                    Haptics.play(.select)
                    period = item
                } label: {
                    Text(item.chip)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(period == item ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(period == item ? Color.white.opacity(0.92) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actionRow(system: String, title: String) -> some View {
        HStack {
            Image(systemName: system)
            Text(title).font(.body.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chart(_ title: String, rows: [ReplayChartRow], circular: Bool = false, onTap: @escaping (ReplayChartRow) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { onTap(row) } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 22)
                        if circular {
                            Circle().fill(.white.opacity(0.12)).frame(width: 40, height: 40)
                                .overlay {
                                    ArtworkView(url: row.art, data: nil, side: 40)
                                        .clipShape(Circle())
                                }
                        } else if row.art != nil {
                            ArtworkView(url: row.art, data: nil, side: 40)
                                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).foregroundStyle(.white).lineLimit(1)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(Int(row.ms / 60_000))m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reload() {
        let name = auth.accountName ?? ""
        model = ReplayModel.load(period: period, holder: name.isEmpty ? "You" : name)
        let artists = model.summary.artists.map(\.name)
        Task {
            await ArtistFacts.shared.warmup(artists: artists)
            var map: [String: [String]] = [:]
            for name in artists {
                map[name] = await ArtistFacts.shared.genresFor(name)
            }
            await MainActor.run {
                ListeningStore.shared.knownGenres = map
                model = ReplayModel.load(period: period, holder: model.holder)
            }
        }
    }
}

private struct ReplayChartRow: Identifiable {
    var id: String
    var rank: Int
    var title: String
    var subtitle: String?
    var art: String?
    var ms: Double
}

private struct StoryRoute: Identifiable {
    var page: ReplayStoryPage
    var id: Int { page.rawValue }
}

/// iOS gets a 9:16 full-screen story; macOS has no `fullScreenCover`.
private struct ReplayStoriesPresentation: ViewModifier {
    @Binding var storyPage: ReplayStoryPage?
    @Binding var shareItem: ReplayShareItem?
    var model: ReplayModel

    private var storyRoute: Binding<StoryRoute?> {
        Binding(
            get: { storyPage.map { StoryRoute(page: $0) } },
            set: { storyPage = $0?.page }
        )
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: storyRoute) { route in
            ReplayStoriesView(model: model, start: route.page) { page in
                shareItem = ReplayShareItem(model: model, page: page)
            }
        }
        #else
        content.sheet(item: storyRoute) { route in
            ReplayStoriesView(model: model, start: route.page) { page in
                shareItem = ReplayShareItem(model: model, page: page)
            }
            .frame(minWidth: 420, minHeight: 720)
        }
        #endif
    }
}

struct ReplayCreditCardView: View {
    let card: ReplayHeroCard
    var holder: String
    var memberSince: String?
    var onClick: () -> Void

    /// The card's figure, tracking Dynamic Type.
    ///
    /// Fixed at 26pt it sat next to a `.caption2` label that grows, so past a
    /// certain text size the number became the *smaller* of the two — backwards on
    /// a card whose whole job is to show a figure. Clamped at both ends, because a
    /// shareable card is a fixed-geometry artefact and a figure that grows without
    /// limit stops fitting the one it is printed on.
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 26

    var body: some View {
        Button(action: onClick) {
            ZStack(alignment: .topLeading) {
                MeshBackdrop(seed: card.value.hashValue)
                LinearGradient(
                    colors: [.black.opacity(0.15), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("BITCHORD")
                            .font(.caption2.weight(.bold))
                            .tracking(1.4)
                        Spacer()
                        Text(card.label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Text(card.value)
                        // Scales, because it sits next to scaled text: fixed at 26pt
                        // it became the *smallest* thing on the card once the
                        // reader's text grew past it. Clamped, because a figure
                        // that grows without limit stops being a figure and starts
                        // being the card.
                        .font(.system(size: min(64, max(26, valueSize)), weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let detail = card.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    HStack {
                        Text(holder.uppercased())
                        Spacer()
                        if let memberSince {
                            Text(memberSince)
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
            }
            .aspectRatio(1.586, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct ReplayBanner: View {
    var onOpen: () -> Void
    @State private var model = ReplayModel.load(period: .thisYear, holder: "You")

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .leading) {
                MeshBackdrop(seed: model.summary.songs.first?.title.hashValue ?? 1)
                LinearGradient(
                    colors: [.black.opacity(0.34), .black.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Replay")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Text(bannerDetail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(18)
            }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear { model = ReplayModel.load(period: .thisYear, holder: "You") }
    }

    private var bannerDetail: String {
        if model.summary.isEmpty {
            return "Top songs, artists, albums and genres — counted on this device"
        }
        return "\(ReplayModel.grouped(model.summary.minutes)) minutes listened · \(model.summary.totalPlays) plays"
    }
}

private struct ReplayStoriesView: View {
    let model: ReplayModel
    let start: ReplayStoryPage
    var onShare: (ReplayStoryPage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var held = false
    /// When the current page's countdown began. The progress bars derive their
    /// width from this against the display clock, so nothing has to poll.
    @State private var pageStartedAt: Date?

    private var pages: [ReplayStoryPage] {
        ReplayStoryPage.allCases.filter { page in
            switch page {
            case .albums: !model.summary.albums.isEmpty
            case .genres: !model.summary.genres.isEmpty
            default: true
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let card = min(geo.size.width, geo.size.height * 9 / 16)
            ZStack {
                Color.black.ignoresSafeArea()
                storyCard
                    .frame(width: card, height: card * 16 / 9)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
            }
            .overlay(alignment: .top) {
                // Driven off the display's own clock rather than by a 20Hz `Task`
                // mutating `@State` every 50ms. Same animation, one fewer wake-up
                // per second, and the bars are smooth because they are redrawn
                // with the display instead of when SwiftUI re-evaluates.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: held)) { timeline in
                    let elapsed = pageStartedAt.map { timeline.date.timeIntervalSince($0) } ?? 0
                    let live = min(max(elapsed / Self.pageDurationSeconds, 0), 1)
                    HStack(spacing: 4) {
                        ForEach(pages.indices, id: \.self) { i in
                            GeometryReader { bar in
                                Capsule().fill(.white.opacity(0.28))
                                Capsule()
                                    .fill(.white)
                                    .frame(
                                        width: bar.size.width
                                            * (i < index ? 1 : i == index ? live : 0)
                                    )
                            }
                            .frame(height: 3)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .padding(.top, 22)
                .padding(.trailing, 8)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in held = true }
                    .onEnded { value in
                        held = false
                        if value.translation.width < -40 { step(true) }
                        else if value.translation.width > 40 { step(false) }
                        else if value.startLocation.x > geo.size.width * 0.55 { step(true) }
                        else { step(false) }
                    }
            )
        }
        .onAppear {
            index = pages.firstIndex(of: start) ?? 0
            pageStartedAt = Date()
        }
        .task(id: "\(index)-\(held)") {
            guard !held else { return }
            // One sleep for the page, not a 20Hz poll. The bars read the clock
            // themselves; this task only has to notice when the page is over.
            guard index < pages.count - 1 else { return }
            try? await Task.sleep(for: Self.pageDuration)
            guard !Task.isCancelled, !held else { return }
            step(true)
        }
        .onChange(of: held) { _, isHeld in
            // Holding pauses the countdown. The clock restarts from zero when the
            // finger lifts, which is what the bar shows.
            if !isHeld { pageStartedAt = Date() }
        }
        .onChange(of: index) { _, _ in pageStartedAt = Date() }
        .environment(\.colorScheme, .dark)
    }

    /// How long one story page holds before advancing.
    private static let pageDuration: Duration = .seconds(4.2)

    /// The same figure in seconds, for the progress bars' arithmetic.
    private static let pageDurationSeconds: Double = 4.2

    private var current: ReplayStoryPage {
        pages.indices.contains(index) ? pages[index] : .intro
    }

    private var storyCard: some View {
        ZStack(alignment: .topLeading) {
            MeshBackdrop(seed: current.rawValue + (model.summary.songs.first?.title.hashValue ?? 0))
            LinearGradient(
                colors: [.black.opacity(0.2), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 16) {
                Spacer().frame(height: 36)
                headline
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                middle
                Spacer()
                Button {
                    onShare(current)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var headline: some View {
        let s = model.summary
        switch current {
        case .intro:
            Text("This is your ") + Text("Replay").bold() + Text(" — the year in music you actually played.")
        case .minutes:
            Text("You listened to ") + Text("\(ReplayModel.grouped(s.minutes)) minutes").bold() + Text(" of music.")
        case .songs:
            Text("You played ") + Text("\(s.totalPlays) songs").bold() + Text(", one was your anthem.")
        case .artists:
            Text("There was one ") + Text("artist").bold() + Text(" you never got tired of.")
        case .albums:
            Text("One ") + Text("album").bold() + Text(" you kept coming back to.")
        case .genres:
            Text("There was one ") + Text("genre").bold() + Text(" you came back to again and again.")
        case .habits:
            Text("You got through ") + Text("\(s.distinctSongs) songs").bold() + Text(" by ") + Text("\(s.distinctArtists) artists").bold() + Text(".")
        case .summary:
            Text("That was ") + Text(s.label).bold() + Text(".")
        }
    }

    /// A size that tracks Dynamic Type, for the numbers a card is *about*.
    ///
    /// `@ScaledMetric` rather than a text style, because these are display figures
    /// whose size is a design decision, not a semantic role — and then clamped at
    /// both ends, because a hero number that grows with the reader is right and a
    /// hero number that grows without limit stops being a hero.
    @ScaledMetric(relativeTo: .largeTitle) private var heroNumberSize: CGFloat = 56

    @ViewBuilder
    private var middle: some View {
        let s = model.summary
        switch current {
        case .intro, .summary:
            if let song = s.songs.first {
                ArtworkView(url: song.art, data: nil, side: 180)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
            }
        case .minutes:
            Text("\(ReplayModel.grouped(s.minutes))")
                // Same reasoning as the stat card, and the failure was more
                // obvious here: the sibling cases of this switch use `.title2`
                // and `.largeTitle`, so at an accessibility text size they grew
                // past a fixed 56pt and the number became the smallest thing on
                // screen — the one element whose whole job is to be read first.
                .font(.system(size: min(150, max(56, heroNumberSize)), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case .songs:
            if let song = s.songs.first {
                VStack(spacing: 8) {
                    ArtworkView(url: song.art, data: nil, side: 160)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    Text(song.title).font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text(song.artist).foregroundStyle(.white.opacity(0.75))
                }
            }
        case .artists:
            if let artist = s.artists.first {
                Text(artist.name).font(.largeTitle.weight(.bold)).foregroundStyle(.white)
            }
        case .albums:
            if let album = s.albums.first {
                Text(album.name).font(.largeTitle.weight(.bold)).foregroundStyle(.white)
            }
        case .genres:
            if let genre = s.genres.first {
                Text(genre.name).font(.largeTitle.weight(.bold)).foregroundStyle(.white)
            }
        case .habits:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(s.distinctSongs) songs").font(.title.weight(.bold))
                Text("\(s.distinctArtists) artists").font(.title.weight(.bold))
                if s.distinctAlbums > 0 {
                    Text("\(s.distinctAlbums) albums").font(.title.weight(.bold))
                }
                if let peak = Self.peakHour(s.hourOfDay) {
                    Text("Loudest around \(peak)").font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func step(_ forward: Bool) {
        // The new page restarts its own countdown; `.onChange(of: index)` resets
        // the clock the bars read from.
        if forward {
            if index < pages.count - 1 { index += 1 }
        } else if index > 0 {
            index -= 1
        }
    }

    private static func peakHour(_ hours: [Double]) -> String? {
        guard let (index, value) = hours.enumerated().max(by: { $0.element < $1.element }),
              value > 0 else { return nil }
        let hour = index % 24
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(suffix)"
    }
}

struct ReplayShareItem: Identifiable {
    let id = UUID()
    var model: ReplayModel
    var page: ReplayStoryPage?
}

private struct ReplayShareSheet: View {
    let item: ReplayShareItem
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ReplayPosterView(model: item.model, page: item.page)
                    .frame(width: 270, height: 480)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .padding(.top, 12)
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share poster", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .navigationTitle("Share")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { fileURL = renderPoster() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    @MainActor
    private func renderPoster() -> URL? {
        // Authored at 1080×1920 and rendered at scale 1. The view is
        // resolution-independent, so this and the share sheet's preview are the
        // same layout rather than one being a crop of the other.
        let poster = ReplayPosterView(model: item.model, page: item.page)
            .frame(width: 1080, height: 1920)
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitchord-replay.png")
        #if os(iOS)
        guard let img = renderer.uiImage, let data = img.pngData() else { return nil }
        try? data.write(to: url)
        return url
        #else
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
        #endif
    }
}

/// The shareable poster, laid out relative to whatever size it is given.
///
/// Deliberately not a fixed 1080×1920 frame. A fixed-size child ignores its
/// parent's proposal, so the share sheet's 270×480 preview was showing a centre
/// crop of a 1080×1920 render — the listener never saw the poster they were
/// about to share. Every dimension is now a multiple of the width it is given,
/// which makes the preview and the export the same layout at two resolutions.
private struct ReplayPosterView: View {
    var model: ReplayModel
    var page: ReplayStoryPage?

    /// The one authored size; everything else scales from it.
    private static let referenceWidth: CGFloat = 1080

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / Self.referenceWidth
            ZStack {
                MeshBackdrop(seed: model.summary.songs.first?.title.hashValue ?? 0)
                LinearGradient(
                    colors: [.black.opacity(0.25), .black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Every font in here is a fixed point size, deliberately, and this
                // is the one place in the app where that is right: it is a
                // shareable poster with a fixed aspect and a composed hierarchy.
                // Scaling it with the sender's text size would make the typography
                // of an image *other people* see depend on the sender's settings,
                // and would break the composition — a 128pt figure beside a
                // 300pt one because someone set their text large. It is a rendered
                // artefact, like a chart's axis labels, not interface text.
                VStack(alignment: .leading, spacing: 16 * k) {
                    Text("BITCHORD REPLAY")
                        .font(.system(size: 30 * k, weight: .bold))
                        .tracking(2 * k)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(model.holder)
                        .font(.system(size: 68 * k, weight: .bold))
                        .foregroundStyle(.white)
                    Text(model.summary.label)
                        .font(.system(size: 40 * k))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(ReplayModel.grouped(model.summary.minutes)) minutes")
                        .font(.system(size: 128 * k, weight: .heavy))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 8 * k) {
                        ForEach(Array(model.summary.songs.prefix(5).enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 24 * k) {
                                Text("\(index + 1).")
                                    .font(.system(size: 44 * k))
                                    .foregroundStyle(.white.opacity(0.5))
                                Text(song.title)
                                    .font(.system(size: 44 * k))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(28 * k)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }
}

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared

/// One recent search, stored as an entity rather than a raw query string:
/// the exact identity (id, artwork, type) of what was tapped, so recents
/// render with real cover art and tapping one navigates straight to it
/// instead of re-running a text search. Port of upstream `SearchHistoryEntity`.
struct RecentSearchEntity: Codable, Identifiable, Hashable {
    /// videoId for tracks, browseId for collections, `q:<query>` for raw text.
    var id: String
    var title: String
    var subtitle: String
    var artworkUrl: String?
    /// TRACK, ALBUM, ARTIST, PLAYLIST or QUERY.
    var entityType: String
    var timestamp: Int64

    init(id: String, title: String, subtitle: String = "", artworkUrl: String? = nil, entityType: String = "QUERY") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.entityType = entityType
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    }

    var typeLabel: String {
        switch entityType.uppercased() {
        case "TRACK": return "Song"
        case "ALBUM": return "Album"
        case "ARTIST": return "Artist"
        case "PLAYLIST": return "Playlist"
        default: return subtitle.isEmpty ? "Search" : subtitle
        }
    }
}

/// Device-only recent searches, kept under the existing `search_history` key.
/// Reads the legacy `[String]` list and migrates each query to a QUERY entity
/// on first write, so an update never drops what was searched before.
enum RecentSearchStore {
    private static let key = "search_history"
    private static let maxEntries = 20

    static func load() -> [RecentSearchEntity] {
        let raw = PlatformSettings.shared.getString(key: key, default: "[]")
        guard let data = raw.data(using: .utf8) else { return [] }
        if let entities = try? JSONDecoder().decode([RecentSearchEntity].self, from: data) {
            // A legacy `["query"]` list fails this decode and falls through;
            // `[]` decodes either way and is empty either way.
            return entities
        }
        let legacy = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return legacy.map { RecentSearchEntity(id: "q:\($0.lowercased())", title: $0) }
    }

    static func record(_ entity: RecentSearchEntity) {
        var list = load().filter { !$0.id.equalsIgnoringCase(entity.id) }
        var fresh = entity
        fresh.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        list.insert(fresh, at: 0)
        save(Array(list.prefix(maxEntries)))
    }

    /// The raw submitted query, for when no result has been tapped yet.
    /// A later tap on a real hit records the rich entity alongside it, which
    /// is what carries the artwork — same as upstream's `recordSearch`.
    static func recordQuery(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        record(RecentSearchEntity(id: "q:\(term.lowercased())", title: term))
    }

    static func remove(id: String) {
        save(load().filter { !$0.id.equalsIgnoringCase(id) })
    }

    static func clear() { save([]) }

    private static func save(_ list: [RecentSearchEntity]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        PlatformSettings.shared.putString(key: key, value: json)
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        compare(other, options: .caseInsensitive) == .orderedSame
    }
}

struct SearchView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    /// Starts on the mixed page, which is what YouTube Music opens on and the only
    /// one that promotes a card. A first search should answer the question rather
    /// than hand back a list.
    @State private var scope: Scope = .all
    @State private var searching = false
    @State private var hits: [SearchHitDTO] = []
    @State private var suggestions: [String] = []
    @State private var searchError: String?
    @State private var attempted = false
    @State private var isSearchPresented = false
    /// Focus for the native search field, including tab reselect and deep links.
    @FocusState private var searchFieldFocused: Bool
    @State private var suggestTask: Task<Void, Never>?
    /// The in-flight search, so leaving the screen or starting a new one can
    /// abandon it. Without a handle the late answer from an abandoned search
    /// writes its results into whatever the screen is showing by then.
    @State private var searchTask: Task<Void, Never>?
    /// Bumped per request to give the results list a new identity, which is what
    /// puts a new result set at the top instead of at the old one's offset.
    @State private var requestToken = 0
    /// The term the results on screen are actually for.
    ///
    /// Not the same as `query`, and the difference is load-bearing: `query` is
    /// what the field says, and the moment it differs from this the results below
    /// are for a search nobody asked for any more. Judging "is the user still
    /// editing" off the suggestions alone got this wrong in two directions — a
    /// one-character edit left the old results up under a shorter query, and
    /// editing after a search never offered completions again.
    @State private var searchedTerm = ""

    enum Scope: String, CaseIterable, Identifiable {
        /// YouTube Music's mixed page — the only one with a promoted card, and so
        /// the only one a top result is shown for.
        case all, songs, videos, albums, artists, playlists

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .videos: return "Videos"
            default: return rawValue.capitalized
            }
        }

        /// Whether a promoted card is worth looking for on this tab.
        ///
        /// A "Songs" search is already entirely songs, and a heading above a list
        /// of the same rows adds nothing.
        var showsTopResult: Bool { self == .all }
    }

    var body: some View {
        NavigationStack {
            resultsColumn
                .navigationTitle("Search")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarLeadingMark()
                    }
                    ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    #endif
                }
                #if os(iOS)
                .searchable(
                    text: $query,
                    isPresented: $isSearchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Artists, Songs, Lyrics, and More"
                )
                #else
                .searchable(text: $query, placement: .toolbar, prompt: "Search")
                #endif
                .searchFocused($searchFieldFocused)
                .onSubmit(of: .search) {
                    Task {
                        await performSearch()
                        searchFieldFocused = false
                    }
                }
                // Upstream's `searchFocusTrigger`: re-tapping the tab that is
                // already selected focuses the field instead of doing nothing.
                // Bound to the counter rather than a flag so a second tap while
                // the first is still being handled is still a tap.
                .onChange(of: appModel.searchFocusTrigger) { _, _ in
                    focusTheField()
                }
                .onChange(of: scope) { _, _ in
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { await performSearch() }
                }
                .onChange(of: query) { _, value in
                    scheduleSuggestions(value)
                    // Clearing or cancelling must not leave old hits visible
                    // below an empty field.
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resetToHistory()
                    }
                }
                .onChange(of: isSearchPresented) { _, presented in
                    if !presented && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resetToHistory()
                    }
                }
                .onChange(of: appModel.focusSearch) { _, focus in
                    guard focus else { return }
                    focusTheField()
                    appModel.focusSearch = false
                }
                .onChange(of: appModel.pendingSearchQuery) { _, pending in
                    guard let pending, !pending.isEmpty else { return }
                    query = pending
                    appModel.pendingSearchQuery = nil
                    Task { await performSearch() }
                }
                .onDisappear { cancelSuggestions() }
        }
    }

    /// Back to the idle screen: no results, no error, no skeletons, and the
    /// recent searches showing again. Not just clearing `hits` — an in-flight
    /// search has to be abandoned too, or it would write its results into a
    /// screen that has already decided it is showing history.
    private func resetToHistory() {
        searchTask?.cancel()
        searchTask = nil
        searching = false
        attempted = false
        hits = []
        searchError = nil
        suggestions = []
        // Nothing on screen is for any term now, which is what stops the
        // old results reappearing under a field that has been emptied.
        searchedTerm = ""
        // A fresh list identity, so the next search starts at the top rather than
        // inheriting wherever the history view was scrolled to.
        requestToken &+= 1
    }

    /// Focus the field.
    ///
    /// One hop through a `Task` on both platforms: the field is part of the
    /// navigation bar, and at the moment a re-tap arrives the view is being
    /// re-selected — the modifier that addresses the field lands on the following
    /// update, so setting focus in the same turn asks a view that is not there
    /// yet.
    private func focusTheField() {
        Task { @MainActor in
            #if os(iOS)
            isSearchPresented = true
            #endif
            searchFieldFocused = true
        }
    }

    /// Cancels an in-flight typeahead request.
    ///
    /// The task used to be cancelled only on the *next* keystroke, so leaving the
    /// screen mid-request left it running and able to write results into a view
    /// that was gone.
    private func cancelSuggestions() {
        suggestTask?.cancel()
        suggestTask = nil
    }

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            // Upstream's rule for the filter tabs, and the reason it is a rule
            // rather than a detail: they only mean something once there is a
            // result set to narrow, and they stay hidden while suggestions are up
            // because everything below them is for whatever was searched before
            // this edit began. They also stay hidden for a search that failed —
            // "pick a filter that finds nothing" would take away the control
            // needed to leave it.
            if showsFilters {
                filterChips
                    .padding(.bottom, 6)
            }

            if searching {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 52) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                }
            } else if attempted && !searching && hits.isEmpty && searchError == nil {
                EmptyStateView(icon: Image(.bchSearch), title: "No results", subtitle: "Nothing found for “\(query)”.", buttonTitle: nil, action: nil)
            } else if let searchError {
                EmptyStateView(icon: Image(.bchSearch), title: "Search unavailable", subtitle: searchError, buttonTitle: nil, action: nil)
            } else if isEditing {
                suggestionList
            } else if !query.isEmpty {
                List {
                    if let top = topResult {
                        // Its own section, with the row chrome taken off, so the
                        // card scrolls away with the results rather than sitting
                        // above a second scroll view — two independent scrollers on
                        // one screen is a thing people fight with.
                        Section {
                            TopResultSection(hit: top, scope: scope) { term in
                                query = term
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    ForEach(sections) { sec in
                        if let title = sec.title {
                            Section {
                                ForEach(sec.hits) { hit in
                                    searchHitRow(hit)
                                }
                            } header: {
                                Text(title)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .textCase(nil)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                        } else {
                            ForEach(sec.hits) { hit in
                                searchHitRow(hit)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // Upstream's `scrollResetTrigger`: one list whose contents change,
                // reset for each new request, so choosing a recent search cannot
                // inherit the history's previous scroll position — or a previous
                // result set's. A new identity per request is what puts it at the
                // top; without it the same `List` keeps its offset and the new
                // results open halfway down.
                .id(requestToken)
            } else {
                history
            }
        }
    }

    private struct SearchSectionModel: Identifiable {
        var id: String { title ?? "all" }
        let title: String?
        let hits: [SearchHitDTO]
    }

    /// Upstream's `searchSections`: when filtering by All, group into Songs, Artists,
    /// Albums, Playlists, and More sections so mixed results are readable at a glance.
    private var sections: [SearchSectionModel] {
        if scope != .all {
            return [SearchSectionModel(title: nil, hits: listHits)]
        }
        let songs = listHits.filter(\.isTrack)
        let artists = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "ARTIST") }
        let albums = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "ALBUM") }
        let playlists = listHits.filter { $0.isBrowse && ($0.browseType?.uppercased() == "PLAYLIST") }
        let more = listHits.filter { $0.isBrowse && !["ARTIST", "ALBUM", "PLAYLIST"].contains($0.browseType?.uppercased() ?? "") }

        var list: [SearchSectionModel] = []
        if !songs.isEmpty { list.append(SearchSectionModel(title: "Songs", hits: songs)) }
        if !artists.isEmpty { list.append(SearchSectionModel(title: "Artists", hits: artists)) }
        if !albums.isEmpty { list.append(SearchSectionModel(title: "Albums", hits: albums)) }
        if !playlists.isEmpty { list.append(SearchSectionModel(title: "Playlists", hits: playlists)) }
        if !more.isEmpty { list.append(SearchSectionModel(title: "More", hits: more)) }
        return list
    }

    @ViewBuilder
    private func searchHitRow(_ hit: SearchHitDTO) -> some View {
        Group {
            if hit.isBrowse, let browseId = hit.browseId {
                NavigationLink(destination: DetailView(browseId: browseId, initialTitle: hit.title)) {
                    browseRow(hit)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    // Tapping a result records the rich entity —
                    // real artwork and type — for the recents list.
                    RecentSearchStore.record(RecentSearchEntity(
                        id: browseId, title: hit.title,
                        subtitle: hit.subtitle ?? "",
                        artworkUrl: hit.thumbnailUrl,
                        entityType: browseEntityType(hit)
                    ))
                })
                .contextMenu {
                    BrowseActionButtons(card: ShelfCard(
                        title: hit.title, subtitle: hit.subtitle,
                        thumbnailUrl: hit.thumbnailUrl, browseId: browseId
                    ))
                }
            } else {
                SongRow(
                    entry: hit.asEntry(),
                    play: {
                        recordTrackEntity(hit)
                        let tracks = listHits.filter(\.isTrack).map { $0.asEntry() }
                        let at = tracks.firstIndex(where: { $0.id == hit.videoId }) ?? 0
                        if scope == .songs {
                            controller.playRadio(hit.asEntry())
                        } else {
                            controller.play(tracks, at: at)
                        }
                    },
                    playNext: { controller.playNext(hit.asEntry()) },
                    addToQueue: { controller.addToQueue(hit.asEntry()) }
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
    }

    /// The trimmed query, in one place. Everywhere below asks the same question
    /// about the field's text and must get the same answer.
    private var term: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the field is mid-edit, so the results below are not the ones for
    /// what it now says.
    ///
    /// Two signals, and either is enough. A non-empty suggestion list is
    /// upstream's signal — a committed search clears the suggestions, so "there
    /// are suggestions" and "the field is being edited" are the same statement.
    /// The second is that the field no longer says what was searched, which
    /// catches the edits too short to produce a suggestion list.
    private var isEditing: Bool {
        !term.isEmpty && (term != searchedTerm || !suggestions.isEmpty)
    }

    /// See [resultsColumn]. Hidden for an empty search, a failed one, and while
    /// typing.
    private var showsFilters: Bool {
        attempted && !searching && searchError == nil && !hits.isEmpty && !isEditing
    }

    private var suggestionList: some View {
        List {
            if !suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(suggestions, id: \.self) { term in
                        suggestionRow(term)
                    }
                }
            }
            // Upstream keeps recent searches in the same column as the
            // suggestions, so a query too short to produce any — or one the
            // service has nothing for — leaves something to tap rather than an
            // empty "Suggestions" header and no way onward.
            let recent = RecentSearchStore.load()
            if !suggestions.isEmpty || !recent.isEmpty {
                if !suggestions.isEmpty { Divider() }
                Section("Recent") {
                    ForEach(recent) { entity in
                        suggestionRow(entity.title)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// One typeahead row: tapping the text searches it, tapping the arrow
    /// fills the field and carries on typing — the pair YouTube, Google and
    /// every mobile keyboard's suggestion strip use.
    private func suggestionRow(_ term: String) -> some View {
        HStack(spacing: 0) {
            Button {
                query = term
                Task { await performSearch() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(term)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                // Fill without searching: the completions update for the
                // longer text and the results stay for what was searched.
                query = term
            } label: {
                Image(systemName: "arrow.up.left")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill search with \(term)")
        }
    }

    private func browseRow(_ hit: SearchHitDTO) -> some View {
        let isArtist = hit.browseType?.uppercased() == "ARTIST"
        return HStack(spacing: 14) {
            if isArtist {
                ArtworkView(url: hit.thumbnailUrl, data: nil, side: 48)
                    .clipShape(Circle())
            } else {
                ArtworkView(url: hit.thumbnailUrl, data: nil, side: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(hit.subtitle ?? hit.browseType ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    #if os(iOS)
    private var pillSelectedTextColor: Color { Color(uiColor: .systemBackground) }
    #else
    private var pillSelectedTextColor: Color { Color(nsColor: .windowBackgroundColor) }
    #endif

    /// Upstream's `SearchFilterTabs`: horizontal scrolling filter pills (All, Songs,
    /// Videos, Albums, Artists, Playlists) with tactile feedback and inverted contrast.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { entry in
                    let selected = entry == scope
                    Button {
                        if !selected {
                            #if os(iOS)
                            let generator = UISelectionFeedbackGenerator()
                            generator.prepare()
                            generator.selectionChanged()
                            #endif
                            withAnimation(.snappy(duration: 0.25)) {
                                scope = entry
                            }
                        }
                    } label: {
                        Text(entry.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color.primary : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? pillSelectedTextColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var history: some View {
        Group {
            let recent = RecentSearchStore.load()
            if recent.isEmpty {
                EmptyStateView(
                    icon: Image(.bchSearch),
                    title: "Search",
                    subtitle: "Find songs, albums, artists and playlists — or connect a local folder in Library for offline listening.",
                    buttonTitle: nil, action: nil
                )
            } else {
                List {
                    Section {
                        ForEach(recent) { entity in
                            recentEntityRow(entity)
                                .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 12))
                        }
                    } header: {
                        HStack {
                            Text("Recent searches")
                            Spacer()
                            Button("Clear") { RecentSearchStore.clear() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .id(requestToken)
            }
        }
    }

    /// Upstream's Spotify-style entity row: square thumbnail, bold title,
    /// subtitle with the type, and a removal button. Tapping navigates to the
    /// entity or plays it directly instead of re-running a text search.
    private func recentEntityRow(_ entity: RecentSearchEntity) -> some View {
        let isArtist = entity.entityType.uppercased() == "ARTIST"
        let isQuery = entity.entityType.uppercased() == "QUERY" || entity.id.hasPrefix("q:")
        return HStack(spacing: 12) {
            Button { openHistoryEntity(entity) } label: {
                HStack(spacing: 14) {
                    if isQuery {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 48, height: 48)
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if isArtist {
                        ArtworkView(url: entity.artworkUrl, data: nil, side: 48)
                            .clipShape(Circle())
                    } else {
                        ArtworkView(url: entity.artworkUrl, data: nil, side: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entity.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if !isQuery {
                            Text(entity.subtitle.isEmpty ? entity.typeLabel : "\(entity.subtitle) · \(entity.typeLabel)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                RecentSearchStore.remove(id: entity.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entity.title) from recent searches")
        }
        .padding(.vertical, 4)
    }

    /// Tapping a history entity navigates or plays without re-logging it —
    /// it is already the most recent record of itself.
    private func openHistoryEntity(_ entity: RecentSearchEntity) {
        switch entity.entityType.uppercased() {
        case "TRACK":
            if entity.id.hasPrefix("q:") {
                query = entity.title
                Task { await performSearch() }
            } else {
                controller.playRadio(QueueEntry.youtube(
                    videoId: entity.id, title: entity.title,
                    artist: entity.subtitle, thumbnailUrl: entity.artworkUrl
                ))
            }
        case "ALBUM", "ARTIST", "PLAYLIST":
            appModel.pendingDetail = .detail(browseId: entity.id, title: entity.title)
        default:
            query = entity.title
            Task { await performSearch() }
        }
    }

    private func scheduleSuggestions(_ value: String) {
        suggestTask?.cancel()
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let list = await InnertubeSearch.shared.suggestions(term)
            await MainActor.run { suggestions = list }
        }
    }

    /// The promoted row, when this tab has one and the search found it.
    ///
    /// Read from the response rather than chosen from the list: it is Google's own
    /// promotion, and a card's track is frequently absent from the results entirely.
    private var topResult: SearchHitDTO? {
        guard scope.showsTopResult else { return nil }
        return hits.first { $0.isTopResult }
    }

    /// Everything that is not the promoted row — the promoted one is not repeated
    /// in the list, so showing both would put the same track on screen twice.
    private var listHits: [SearchHitDTO] {
        guard scope.showsTopResult else { return hits }
        return hits.filter { !$0.isTopResult }
    }

    /// Records a tapped track with its real artwork and artist, so recents
    /// show the song rather than the words that found it.
    private func recordTrackEntity(_ hit: SearchHitDTO) {
        guard let videoId = hit.videoId else { return }
        RecentSearchStore.record(RecentSearchEntity(
            id: videoId, title: hit.title,
            subtitle: hit.subtitle ?? "",
            artworkUrl: hit.thumbnailUrl,
            entityType: "TRACK"
        ))
    }

    /// Maps a browse hit's type to the entity type the recents list files it
    /// under — album, artist, playlist, or a track carrying a browse id.
    private func browseEntityType(_ hit: SearchHitDTO) -> String {
        switch (hit.browseType ?? "").uppercased() {
        case "ALBUM": return "ALBUM"
        case "ARTIST": return "ARTIST"
        case "PLAYLIST": return "PLAYLIST"
        default: return "TRACK"
        }
    }

    private func performSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        // A new request abandons the previous one. Two searches in flight meant
        // the slower one could land last and overwrite the newer results, which
        // is the bug a listener sees as "I searched for the right thing and got
        // the wrong thing".
        searchTask?.cancel()
        searching = true
        attempted = true
        searchError = nil
        suggestions = []
        // A new list identity per request, so the results open at the top rather
        // than at the previous set's offset.
        requestToken &+= 1
        RecentSearchStore.recordQuery(term)
        searchedTerm = term
        let wanted = scope
        let task = Task { @MainActor in
            do {
                var found = try await InnertubeSearch.shared.search(term, scope: wanted.rawValue)
                if PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true), wanted == .songs {
                    let extra = await JioSaavn.search(term)
                    found.insert(contentsOf: extra, at: 0)
                }
                // Cancellation can arrive while the network call is in flight, so
                // the guard is checked again here rather than trusted to have been
                // checked before the request.
                guard !Task.isCancelled else { return }
                hits = found
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Couldn't reach the music service. Check your connection and try again."
                hits = []
            }
            searching = false
            searchTask = nil
        }
        searchTask = task
        _ = await task.value
    }
}

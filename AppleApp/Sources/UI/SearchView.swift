import SwiftUI
import BitChordShared

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
    /// The platform search field's own focus, addressed through
    /// `searchFocused(_:)`. The modifier exists from iOS 18 / macOS 15, which is
    /// the project's floor.
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
                .toolbarTitleDisplayMode(.inline)
                // The platform's own search field, on both platforms.
                //
                // iOS used to get a hand-rolled `TextField` in a `Capsule` with a
                // 13-point glyph in it, and that is what the port was missing: no
                // Cancel, no native clear button, no "Search" return key, and
                // nothing for VoiceOver to label. All of those come with the real
                // control, and hand-rolling them again is exactly the kind of local
                // hack this port is supposed to be removing. `always` rather than
                // `automatic` because upstream's field is always on screen — a
                // search that appears only after a pull is a different screen.
                .searchable(text: $query, placement: searchPlacement, prompt: "Search")
                .searchFocused($searchFieldFocused)
                .onSubmit(of: .search) { Task { await performSearch() } }
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
                    // The field's own Cancel empties the text without telling the
                    // results anything, so the screen would keep showing the last
                    // search's hits under an empty field. Upstream reaches the
                    // recent-searches view the same way — one tap on the clear
                    // button — and here that tap is Cancel, so this is the
                    // equivalent of the clear button's own reset.
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    /// Where the platform puts the field.
    ///
    /// iOS's navigation-bar drawer, shown always rather than on pull, because
    /// upstream's field is always on screen and a search that appears only after
    /// a pull is a different screen. On macOS the field belongs in the window
    /// toolbar. Stated on both rather than left to a default, so the two are not
    /// left to a compiler that may choose differently on either.
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .toolbar
        #endif
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
                scopePicker
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
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
                    ForEach(Array(listHits.enumerated()), id: \.element.id) { _, hit in
                        Group {
                            if hit.isBrowse, let browseId = hit.browseId {
                                NavigationLink(destination: DetailView(browseId: browseId, initialTitle: hit.title)) {
                                    browseRow(hit)
                                }
                                .buttonStyle(.plain)
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
                        .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 2, trailing: 28))
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
                        Button(term) {
                            query = term
                            Task { await performSearch() }
                        }
                    }
                }
            }
            // Upstream keeps recent searches in the same column as the
            // suggestions, so a query too short to produce any — or one the
            // service has nothing for — leaves something to tap rather than an
            // empty "Suggestions" header and no way onward.
            let recent = Self.recentSearches()
            if !suggestions.isEmpty || !recent.isEmpty {
                if !suggestions.isEmpty { Divider() }
                Section("Recent") {
                    ForEach(recent, id: \.self) { term in
                        Button(term) {
                            query = term
                            Task { await performSearch() }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func browseRow(_ hit: SearchHitDTO) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: hit.thumbnailUrl, data: nil, side: 44)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).lineLimit(1)
                Text(hit.subtitle ?? hit.browseType ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var scopePicker: some View {
        Picker("Kind", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }

    private var history: some View {
        Group {
            let recent = Self.recentSearches()
            if recent.isEmpty {
                EmptyStateView(
                    icon: Image(.bchSearch),
                    title: "Search",
                    subtitle: "Find songs, albums, artists and playlists — or connect a local folder in Library for offline listening.",
                    buttonTitle: nil, action: nil
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent searches").font(.headline)
                        Spacer()
                        Button("Clear") { SearchHistory.shared.clear() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 28)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(recent, id: \.self) { term in
                                Button {
                                    query = term
                                    Task { await performSearch() }
                                } label: {
                                    Text(term)
                                        .font(.callout)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove") { SearchHistory.shared.remove(query: term) }
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
            }
        }
    }

    static func recentSearches() -> [String] {
        let raw = PlatformSettings.shared.getString(key: "search_history", default: "[]")
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
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
        SearchHistory.shared.record(query: term)
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

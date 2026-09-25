import SwiftUI
import BitChordShared

struct SearchView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var scope: Scope = .songs
    @State private var searching = false
    @State private var hits: [SearchHitDTO] = []
    @State private var suggestions: [String] = []
    @State private var searchError: String?
    @State private var attempted = false
    @FocusState private var fieldFocused: Bool
    /// macOS. The `.searchable` field lives in the window's toolbar on that
    /// platform, so the iOS `fieldFocused` above never reached it — ⌘F and
    /// re-selecting the Search tab did nothing. A second `FocusState` bound
    /// through `searchFocused(_:)` is what addresses the toolbar field; the
    /// modifier exists from iOS 18 / macOS 15, which is the project's floor.
    @FocusState private var searchFieldFocused: Bool
    @State private var suggestTask: Task<Void, Never>?

    enum Scope: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            resultsColumn
                .navigationTitle("Search")
                #if os(macOS)
                .toolbarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search")
                .searchFocused($searchFieldFocused)
                .onSubmit(of: .search) { Task { await performSearch() } }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Kind", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                #endif
                .onChange(of: scope) { _, _ in
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { await performSearch() }
                }
                .onChange(of: query) { _, value in
                    scheduleSuggestions(value)
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

    /// Focus the field on whichever platform this is.
    ///
    /// Two mechanisms because the field is in a different place on each: a real
    /// `TextField` in the content column on iOS, the window toolbar's
    /// `.searchable` field on macOS. Only the iOS one is reachable by
    /// `@FocusState`.
    private func focusTheField() {
        #if os(macOS)
        searchFieldFocused = true
        #else
        fieldFocused = true
        #endif
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
            #if os(iOS)
            searchField
                .padding(.horizontal, 24)
                .padding(.top, 14)
            HStack {
                Spacer(minLength: 0)
                scopePicker
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            #endif

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
            } else if !query.isEmpty && !suggestions.isEmpty && !attempted {
                suggestionList
            } else if !query.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
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
                                        let tracks = hits.filter { !$0.isBrowse }.map { $0.asEntry() }
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
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
            } else {
                history
            }
        }
    }

    private var suggestionList: some View {
        List {
            Section("Suggestions") {
                ForEach(suggestions, id: \.self) { term in
                    Button(term) {
                        query = term
                        Task { await performSearch() }
                    }
                }
            }
        }
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

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(.bchSearch)
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .font(.body)
                .onSubmit { Task { await performSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                    searchError = nil
                    attempted = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: Capsule())
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

    private func performSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true
        attempted = true
        searchError = nil
        suggestions = []
        SearchHistory.shared.record(query: term)
        defer { searching = false }
        do {
            hits = try await InnertubeSearch.shared.search(term, scope: scope.rawValue)
            if PlatformSettings.shared.getBoolean(key: "jiosaavn_enabled", default: true), scope == .songs {
                let extra = await JioSaavn.search(term)
                hits.insert(contentsOf: extra, at: 0)
            }
        } catch {
            searchError = "Couldn't reach the music service. Check your connection and try again."
            hits = []
        }
    }
}

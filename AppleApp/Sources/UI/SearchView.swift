import SwiftUI
import BitChordShared

/// Search tab (UI spec §5 macOS nuance): field at the top of the content
/// column with a scope segmented control under it, recent-search history from
/// the shared module's `SearchHistory`. Results come from the innertube port
/// (milestone 2).
struct SearchView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var query = ""
    @State private var scope: Scope = .songs
    @State private var searching = false
    @State private var results: [QueueEntry] = []
    @State private var searchError: String?
    @State private var attempted = false
    @FocusState private var fieldFocused: Bool

    enum Scope: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                HStack {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                if let playError = controller.lastError, !playError.isEmpty {
                    Text(playError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.red.opacity(0.85), in: .rect(cornerRadius: 8))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                }
                if searching {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(0..<8, id: \.self) { _ in
                                SkeletonBlock(height: 52)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                } else if attempted && !searching && results.isEmpty && searchError == nil {
                    EmptyStateView(
                        icon: Image(.bchSearch),
                        title: "No results",
                        subtitle: "Nothing found for “\(query)”.",
                        buttonTitle: nil, action: nil
                    )
                } else if let searchError {
                    EmptyStateView(
                        icon: Image(.bchSearch),
                        title: "Search unavailable",
                        subtitle: searchError,
                        buttonTitle: nil, action: nil
                    )
                } else if !query.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                SongRow(
                                    entry: entry,
                                    play: { controller.play(results, at: index) },
                                    playNext: { controller.playNext(entry) },
                                    addToQueue: { controller.addToQueue(entry) }
                                )
                                Divider().opacity(0.3)
                            }
                        }
                    }
                } else {
                    history
                }
            }
            .navigationTitle("Search")
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(.bchSearch)
                .resizable()
                .scaledToFit()
                .frame(width: 15)
                .foregroundStyle(.secondary)
            TextField("Search YouTube Music", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .font(.body)
                .onSubmit { Task { await performSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    searchError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var history: some View {
        Group {
            let recent = Self.recentSearches()
            if recent.isEmpty {
                EmptyStateView(
                    icon: Image(.bchSearch),
                    title: "Search YouTube Music",
                    subtitle: "Find songs, albums, artists and playlists — or connect a local folder in Library for offline listening.",
                    buttonTitle: nil, action: nil
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent searches")
                        .font(.headline)
                        .padding(.horizontal, 24)
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
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }
        }
    }

    static func recentSearches() -> [String] {
        let raw = PlatformSettings.shared.getString(key: "search_history", default: "[]")
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    private func performSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true
        attempted = true
        searchError = nil
        SearchHistory.shared.record(query: term)
        defer { searching = false }
        do {
            let songs = try await InnertubeSearch.shared.search(term, scope: scope.rawValue)
            results = songs.map { song in
                QueueEntry(
                    id: song.videoId,
                    title: song.title,
                    artist: song.artist,
                    source: "yt:\(song.videoId)",
                    thumbnailUrl: song.thumbnailUrl,
                    durationText: song.durationText,
                    albumName: song.albumName,
                    artworkData: nil,
                    isLocal: false
                )
            }
        } catch {
            searchError = "Couldn't reach YouTube Music. Check your connection and try again. (\(error.localizedDescription))"
            results = []
        }
    }
}

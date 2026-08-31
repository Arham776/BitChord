import SwiftUI

struct ReplayView: View {
    @State private var summary = ListeningStore.shared.summary()
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            Group {
                if summary.isEmpty {
                    EmptyStateView(
                        icon: Image(.bchClock),
                        title: "Your Replay is growing",
                        subtitle: "Play a few songs and this page will fill in with minutes, top tracks and artists.",
                        buttonTitle: nil, action: nil
                    )
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(summary.minutes)")
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                Text("minutes listened")
                                    .foregroundStyle(.secondary)
                                Text("\(summary.totalPlays) plays")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        if let day = summary.busiestDay {
                            Section("Biggest day") {
                                Text("\(day) · \(Int(summary.busiestDayMs / 60_000)) min")
                            }
                        }
                        Section("Top songs") {
                            ForEach(summary.songs) { song in
                                Button {
                                    controller.play([
                                        QueueEntry.youtube(
                                            videoId: song.id, title: song.title, artist: song.artist,
                                            thumbnailUrl: song.art, albumName: song.album,
                                            artistId: song.artistId, albumId: song.albumId
                                        )
                                    ], at: 0)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(song.title)
                                            Text(song.artist).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(Int(song.ms / 60_000))m")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section("Top artists") {
                            ForEach(summary.artists) { row in
                                Button {
                                    if let id = row.browseId {
                                        appModel.pendingDetail = .detail(browseId: id, title: row.name)
                                    }
                                } label: {
                                    HStack {
                                        Text(row.name)
                                        Spacer()
                                        Text("\(Int(row.ms / 60_000))m").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section("Top albums") {
                            ForEach(summary.albums) { row in
                                Button {
                                    if let id = row.browseId {
                                        appModel.pendingDetail = .detail(browseId: id, title: row.name)
                                    }
                                } label: {
                                    HStack {
                                        Text(row.name)
                                        Spacer()
                                        Text("\(Int(row.ms / 60_000))m").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !summary.genres.isEmpty {
                            Section("Top genres") {
                                ForEach(summary.genres) { row in
                                    HStack {
                                        Text(row.name)
                                        Spacer()
                                        Text("\(Int(row.ms / 60_000))m").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Replay")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { appModel.replayPresented = false }
                }
            }
            .onAppear {
                summary = ListeningStore.shared.summary()
                let artists = summary.artists.map(\.name)
                Task {
                    await ArtistFacts.shared.warmup(artists: artists)
                    var map: [String: [String]] = [:]
                    for name in artists {
                        map[name] = await ArtistFacts.shared.genresFor(name)
                    }
                    await MainActor.run {
                        ListeningStore.shared.knownGenres = map
                        summary = ListeningStore.shared.summary()
                    }
                }
            }
        }
    }
}

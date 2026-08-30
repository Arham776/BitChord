import SwiftUI

/// Detail page for an album / artist / playlist browseId.
struct DetailView: View {
    let browseId: String
    let initialTitle: String
    @Environment(PlaybackController.self) private var controller
    @State private var page: DetailPageModel?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ScrollView { FeedSkeleton() }
            } else if let error {
                EmptyStateView(icon: Image(.bchMusicNote), title: "Couldn't load", subtitle: error, buttonTitle: "Retry") {
                    Task { await load() }
                }
            } else if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(page)
                        if !page.songs.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(page.songs.enumerated()), id: \.element.videoId) { index, song in
                                    SongRow(
                                        entry: QueueEntry(
                                            id: song.videoId,
                                            title: song.title,
                                            artist: song.artist,
                                            source: "yt:\(song.videoId)",
                                            thumbnailUrl: song.thumbnailUrl,
                                            durationText: song.durationText,
                                            albumName: nil,
                                            artworkData: nil,
                                            isLocal: false
                                        ),
                                        play: { controller.play(page.songs.map(toEntry), at: index) }
                                    )
                                    Divider().opacity(0.3)
                                }
                            }
                        } else {
                            EmptyStateView(icon: Image(.bchMusicNote), title: "No tracks", subtitle: "This page has no playable tracks.", buttonTitle: nil, action: nil)
                        }
                        if let desc = page.description, !desc.isEmpty {
                            Text(desc)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)
                        }
                        ForEach(page.sections) { shelf in
                            ShelfCarousel(shelf: shelf)
                                .padding(.horizontal, 24)
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle(page?.title.isEmpty == false ? page!.title : initialTitle)
        .task { await load() }
    }

    private func header(_ page: DetailPageModel) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(url: page.thumbnailUrl, data: nil, side: 140)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(page.title.isEmpty ? initialTitle : page.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                if !page.subtitle.isEmpty {
                    Text(page.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let sub = page.subscriberCountText, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if page.songs.count > 0 {
                    Button("Play all") {
                        controller.play(page.songs.map(toEntry), at: 0)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func toEntry(_ s: DetailPageModel.SongPayload) -> QueueEntry {
        QueueEntry(id: s.videoId, title: s.title, artist: s.artist, source: "yt:\(s.videoId)", thumbnailUrl: s.thumbnailUrl, durationText: s.durationText, albumName: nil, artworkData: nil, isLocal: false)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            // Try generic browse; if it returns empty title but has songs, keep it.
            // For UC browseIds the artist endpoint gives richer data.
            if browseId.hasPrefix("UC") {
                page = try await InnertubeDetail.shared.browseArtist(browseId: browseId)
                if page?.songs.isEmpty == true {
                    page = try await InnertubeDetail.shared.browse(browseId: browseId)
                }
            } else {
                page = try await InnertubeDetail.shared.browse(browseId: browseId)
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

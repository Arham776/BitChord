import SwiftUI
import BitChordShared

/// A WebDAV share, read as a library.
///
/// Upstream's `local:webdav` detail page, and the same three states it has: a share
/// that answered with tracks, a share that answered with none, and a share that
/// refused. They are drawn differently on purpose — see [WebDavStore.State] — because
/// "no audio files" sent to somebody whose password has changed is a bug report they
/// file and we cannot answer.
///
/// The albums are the folders on the share, which is what makes this feel like a
/// library rather than a file listing without reading a single tag.
struct WebDavLibraryView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var store = WebDavStore.shared
    /// Where the page was when it last loaded, so a change to the share is a
    /// deliberate re-read rather than a silent one.
    @State private var loadedFor: String = ""

    var body: some View {
        content
            .task(id: store.url) {
                // Keyed on the address, so pointing the app at a different share
                // re-reads rather than showing the old one's albums — and a share that
                // was just set up loads on arrival instead of waiting for a pull.
                guard loadedFor != store.url else { return }
                loadedFor = store.url
                await store.load(force: true)
            }
            .refreshable { await store.load(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .notConfigured:
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "No remote library yet",
                subtitle: "Point BitChord at a WebDAV share in Sources and it will appear here.",
                buttonTitle: nil,
                action: nil
            )
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Nothing on that share",
                subtitle: "The server answered and there is no audio in it. If you expected a folder here, it may be somewhere else on the share.",
                buttonTitle: nil,
                action: nil
            )
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchLibrary),
                title: "Can’t read that share",
                subtitle: message,
                buttonTitle: "Try Again",
                action: { Task { await store.load(force: true) } }
            )
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                header
            }
            ForEach(store.albums) { album in
                Section {
                    ForEach(Array(album.songs.enumerated()), id: \.element.videoId) { _, song in
                        SongRow(
                            entry: entry(for: song),
                            play: { play(song) }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                    }
                } header: {
                    AlbumHeader(album: album)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("WebDAV")
    }

    /// Which share this is, and how much of it there is.
    ///
    /// Above the tracks rather than in a toolbar, because it is the answer to the
    /// question a remote page raises first — is this the share I meant? — and a
    /// toolbar title is the worst place on a Mac window to put a sentence.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var countLabel: String {
        let albums = store.albums.count
        let tracks = store.trackCount
        let albumWord = albums == 1 ? "album" : "albums"
        let trackWord = tracks == 1 ? "track" : "tracks"
        return "\(albums) \(albumWord) · \(tracks) \(trackWord)"
    }

    private func entry(for song: Song) -> QueueEntry { QueueEntry.from(song) }

    /// Play a track, with the rest of the share behind it.
    ///
    /// The whole share rather than the album, because a queue that stopped at the end
    /// of an album is not what anybody means by pressing play in a library, and
    /// re-ordering by hand is a worse answer than a sensible one.
    private func play(_ song: Song) {
        let entries = store.albums.flatMap { $0.songs }.map(entry(for:))
        guard let index = entries.firstIndex(where: { $0.id == song.videoId }) else { return }
        controller.play(entries, at: index)
    }
}

/// One folder's heading: its cover, and its name.
private struct AlbumHeader: View {
    let album: WebDavStore.RemoteAlbum

    var body: some View {
        HStack(spacing: 10) {
            // The embedded cover is only asked for when no picture was filed: the
            // task behind `remoteId` runs whatever the other fields say, and a folder
            // with a real `cover.jpg` should not pay for a ranged read to find out
            // that it does not need one. Upstream resolves the first track's embedded
            // picture the same way.
            ArtworkView(
                url: album.coverUrl,
                data: nil,
                side: 34,
                remoteId: album.coverUrl == nil ? album.id : nil
            )
            .clipShape(.rect(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name ?? "Unknown album")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(album.songs.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name ?? "Unknown album"), \(album.songs.count) tracks")
    }
}

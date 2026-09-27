import SwiftUI
import BitChordShared

/// The promoted result: what YouTube Music says the listener meant.
///
/// A card rather than a row, because the thing it carries is the *answer* to the
/// query — a heading above a list of equally plausible rows is what tells someone
/// "not those, this one". The row list below is the other reading of the same
/// words, not a continuation of this one.
struct TopResultSection: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel

    let hit: SearchHitDTO
    let scope: SearchView.Scope
    /// "Go to album" needs a query rather than an id, because the album page is
    /// reached by name — and by the time someone wants it, the name is what they
    /// typed.
    let onGoToAlbum: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top result")
                .font(.headline)
                .padding(.horizontal, 24)

            card
                .padding(.horizontal, 24)
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                artwork
                details
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            actionsRow
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.title), \(hit.subtitle ?? "")")
        .accessibilityHint("Plays the top result")
    }

    @ViewBuilder
    private var artwork: some View {
        let isArtist = hit.browseType?.uppercased() == "ARTIST"
        if let url = hit.thumbnailUrl, !url.isEmpty {
            AsyncImage(url: URL(string: url)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 72, height: 72)
            .modifier(ArtworkClipModifier(isArtist: isArtist))
        } else {
            artworkPlaceholder
                .frame(width: 72, height: 72)
        }
    }

    private struct ArtworkClipModifier: ViewModifier {
        let isArtist: Bool
        func body(content: Content) -> some View {
            if isArtist {
                content.clipShape(Circle())
            } else {
                content.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.title)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let subtitle = hit.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let album = hit.albumName, !album.isEmpty, let artist = hit.subtitle {
                Button(album) { onGoToAlbum("\(artist) \(album)") }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Upstream's `TopResultCard` button pair: Play and Add to Playlist.
    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            Button {
                if let videoId = hit.videoId {
                    RecentSearchStore.record(RecentSearchEntity(
                        id: videoId, title: hit.title,
                        subtitle: hit.subtitle ?? "",
                        artworkUrl: hit.thumbnailUrl,
                        entityType: "TRACK"
                    ))
                    appModel.playlistPicker = PlaylistPickerRequest(
                        videoId: videoId, title: hit.title
                    )
                }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(hit.videoId == nil)
        }
    }

    @ViewBuilder
    private var menu: some View {
        // The same three actions every other row offers, so the card is not a
        // place where the queue cannot be reached from.
        let entry = hit.asEntry()
        Button("Play") { play() }
        Button("Play Next") { controller.playNext(entry) }
        Button("Add to Queue") { controller.addToQueue(entry) }
    }

    /// The top result plays on its own.
    ///
    /// Deliberately not "play the results from here": the card is a single answer,
    /// and tapping it should play *that*, the way a link does. A listener who
    /// wants the list presses the first row.
    private func play() {
        if let videoId = hit.videoId {
            RecentSearchStore.record(RecentSearchEntity(
                id: videoId, title: hit.title,
                subtitle: hit.subtitle ?? "",
                artworkUrl: hit.thumbnailUrl,
                entityType: "TRACK"
            ))
        }
        controller.playRadio(hit.asEntry())
    }
}

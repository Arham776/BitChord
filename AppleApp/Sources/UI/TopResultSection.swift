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
        HStack(spacing: 16) {
            artwork
            details
            playButton
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
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
        if let url = hit.thumbnailUrl, !url.isEmpty {
            AsyncImage(url: URL(string: url)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 92, height: 92)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                .font(.title3.weight(.semibold))
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

    private var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Play the top result")
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
        controller.playRadio(hit.asEntry())
    }
}

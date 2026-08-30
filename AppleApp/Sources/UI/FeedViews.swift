import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Loads one signed-out feed (Home or Explore) off the shared bridge,
/// upstream's `UiState` loading/error/success shape.
@MainActor @Observable
final class FeedLoader {
    enum Source { case home, explore }
    enum Phase { case loading, loaded([FeedShelf]), failed(String) }

    private(set) var phase: Phase = .loading
    private let source: Source

    init(_ source: Source) {
        self.source = source
    }

    func load() async {
        phase = .loading
        do {
            let shelves = source == .home
                ? try await InnertubeFeed.shared.home()
                : try await InnertubeFeed.shared.explore()
            phase = .loaded(shelves)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Upstream's shelf carousel: bold heading over a horizontal run of cards.
/// Cards are tappable — a track card plays immediately, an album/playlist/artist
/// card navigates to its detail page (spec parity with upstream's two-row cards).
struct ShelfCarousel: View {
    let shelf: FeedShelf
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { card in
                        ShelfCardView(card: card)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct ShelfCardView: View {
    let card: ShelfCard
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        Group {
            if let browseId = card.browseId, !browseId.isEmpty {
                NavigationLink(destination: DetailView(browseId: browseId, initialTitle: card.title)) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else if let videoId = card.videoId, !videoId.isEmpty {
                Button {
                    let entry = QueueEntry(
                        id: videoId,
                        title: card.title,
                        artist: card.subtitle ?? "",
                        source: "yt:\(videoId)",
                        thumbnailUrl: card.thumbnailUrl,
                        durationText: nil,
                        albumName: nil,
                        artworkData: nil,
                        isLocal: false
                    )
                    controller.play([entry], at: 0)
                } label: {
                    cardContent
                        .overlay(alignment: .topLeading) {
                            if controller.current?.id == videoId && controller.isBuffering {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(8)
                            }
                        }
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: card.thumbnailUrl, data: nil, side: 160)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
            Text(card.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 160, alignment: .leading)
        .contentShape(.rect)
    }
}

/// Navigation destination for detail drill-down from any shelf.
enum BrowseDestination: Hashable {
    case detail(browseId: String, title: String)
}

/// Upstream's `SignInBanner`. Opens the in-app Google login WebView — never
/// the system browser, which would put the session in Safari instead of here.
struct SignInBanner: View {
    var onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to YouTube Music")
                    .font(.headline)
                Text("Personalized recommendations and your library, on every device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Sign In", action: onSignIn)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Upstream `feedSkeleton()` — shimmer shelves while the feed loads.
struct FeedSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 22, cornerRadius: 6)
                        .frame(width: 140)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(0..<5, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(height: 160, cornerRadius: 10)
                                    SkeletonBlock(height: 14, cornerRadius: 4)
                                        .frame(width: 120)
                                    SkeletonBlock(height: 12, cornerRadius: 4)
                                        .frame(width: 80)
                                }
                                .frame(width: 160)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

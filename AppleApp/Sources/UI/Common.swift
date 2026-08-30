import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Async artwork: YouTube thumbnail URLs, or embedded local artwork bytes.
/// Upstream sizes via the `w<n>-h<n>` hint (`Song.artworkAt` in shared).
struct ArtworkView: View {
    var url: String?
    var data: Data?
    var side: CGFloat?

    init(entry: QueueEntry?, side: CGFloat? = nil) {
        self.init(url: entry?.thumbnailUrl, data: entry?.artworkData, side: side)
    }

    init(url: String?, data: Data?, side: CGFloat? = nil) {
        self.url = url.flatMap { SharedArtwork.sized($0, Int((side ?? 300) * 2)) }
        self.data = data
        self.side = side
    }

    var body: some View {
        Group {
#if os(iOS)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url, let cached = ArtworkCache.shared.get(url) {
                Image(uiImage: cached)
                    .resizable()
                    .scaledToFill()
            } else if let url {
                RemoteArtwork(url: url)
            } else {
                placeholder
            }
#else
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url, let cached = ArtworkCache.shared.get(url) {
                Image(nsImage: cached)
                    .resizable()
                    .scaledToFill()
            } else if let url {
                RemoteArtwork(url: url)
            } else {
                placeholder
            }
#endif
        }
        .frame(width: side, height: side)
        .aspectRatio(1, contentMode: .fit)
        .background(.quaternary)
        .clipped()
        .id("\(url ?? "")-\(data?.count ?? 0)")
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            GeometryReader { proxy in
                Image(.bchMusicNote)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width * 0.4)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct RemoteArtwork: View {
    let url: String
#if os(iOS)
    @State private var image: UIImage?
#else
    @State private var image: NSImage?
#endif

    var body: some View {
        Group {
#if os(iOS)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary.opacity(0.6))
                    .overlay(ProgressView().controlSize(.mini))
            }
#else
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary.opacity(0.6))
                    .overlay(ProgressView().controlSize(.mini))
            }
#endif
        }
        .task(id: url) {
            image = nil
            image = await ArtworkCache.shared.load(url)
        }
    }
}

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
#if os(iOS)
    private var cache: [String: UIImage] = [:]
    func get(_ url: String) -> UIImage? { cache[url] }
    func load(_ url: String) async -> UIImage? {
        if let hit = cache[url] { return hit }
        guard let endpoint = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let image = UIImage(data: data) else { return nil }
        cache[url] = image
        return image
    }
#else
    private var cache: [String: NSImage] = [:]
    func get(_ url: String) -> NSImage? { cache[url] }
    func load(_ url: String) async -> NSImage? {
        if let hit = cache[url] { return hit }
        guard let endpoint = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let image = NSImage(data: data) else { return nil }
        cache[url] = image
        return image
    }
#endif
}

enum SharedArtwork {
    /// `String?.artworkAt(px)` from the shared module's model helpers.
    static func sized(_ url: String, _ px: Int) -> String? {
        guard let match = url.range(of: #"w\d+-h\d+"#, options: .regularExpression) else {
            return url
        }
        return url.replacingCharacters(in: match, with: "w\(px)-h\(px)")
    }
}

/// Upstream `Skeletons.kt`'s shimmer — the loading look on every feed.
struct SkeletonBlock: View {
    var height: CGFloat
    var cornerRadius: CGFloat = 8
    @State private var phase: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(height: height)
            .opacity(phase ? 0.5 : 0.9)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

/// Music's centered empty state: glyph, bold title, subtitle, one bordered button.
struct EmptyStateView: View {
    var icon: Image
    var title: String
    var subtitle: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 42)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// A queue row: artwork, title/artist, duration; hover highlight, context
/// menu (macOS nuance from UI spec §5).
struct SongRow: View {
    let entry: QueueEntry
    var isCurrent: Bool = false
    var play: () -> Void
    var playNext: (() -> Void)?
    var addToQueue: (() -> Void)?

    @Environment(PlaybackController.self) private var controller
    @State private var hovering = false

    private var active: Bool { isCurrent || controller.current?.id == entry.id }
    private var buffering: Bool { controller.current?.id == entry.id && controller.isBuffering }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ZStack {
                    ArtworkView(entry: entry, side: 44)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    if buffering {
                        ProgressView().controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.body.weight(active ? .bold : .medium))
                        .foregroundStyle(active ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let text = entry.durationText, !text.isEmpty {
                    Text(text)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(.bchChevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play", action: play)
            if let playNext {
                Button("Play Next", action: playNext)
            }
            if let addToQueue {
                Button("Add to Queue", action: addToQueue)
            }
        }
    }
}

/// Upstream `ThinSlider.kt` — hairline track, small knob, timestamp labels.
struct ThinSlider: View {
    let value: Double
    let maximum: Double
    var onEditingChanged: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double?

    private var effective: Double { dragging ? (dragValue ?? value) : value }

    var body: some View {
        Slider(
            value: Binding(
                get: { maximum > 0 ? min(effective, maximum) : 0 },
                set: { dragValue = $0; dragging = true }
            ),
            in: 0...max(maximum, 0.01)
        ) { editing in
            if !editing {
                if let v = dragValue { onEditingChanged(v) }
                dragging = false
                dragValue = nil
            }
        }
        .controlSize(.small)
    }
}

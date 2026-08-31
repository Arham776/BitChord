import SwiftUI
import BitChordShared
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

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// Memory + disk artwork cache — Apple stand-in for Coil's LRU.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, PlatformImage>()
    private let folder = DiskCache.cachesSubfolder("images")
    private static let diskLimit: Int64 = 128 * 1024 * 1024

    init() {
        memory.totalCostLimit = 48 * 1024 * 1024
        memory.countLimit = 400
    }

    func get(_ url: String) -> PlatformImage? {
        if let hit = memory.object(forKey: url as NSString) { return hit }
        let file = diskURL(url)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let image = PlatformImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSString, cost: data.count)
        DiskCache.touch(file)
        return image
    }

    func load(_ url: String) async -> PlatformImage? {
        if let hit = get(url) { return hit }
        guard let endpoint = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let image = PlatformImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSString, cost: data.count)
        let file = diskURL(url)
        try? data.write(to: file, options: .atomic)
        DiskCache.trimFolder(folder, limitBytes: Self.diskLimit)
        return image
    }

    func clear() {
        memory.removeAllObjects()
        DiskCache.clearFolder(folder)
    }

    private func diskURL(_ url: String) -> URL {
        folder.appendingPathComponent(DiskCache.hashName(url))
    }
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
/// menu (macOS nuance from UI spec §5). Rows always show a sleeve — album
/// tracks that omit per-song art inherit the page cover at the call site.
struct SongRow: View {
    let entry: QueueEntry
    var isCurrent: Bool = false
    var play: () -> Void
    var playNext: (() -> Void)?
    var addToQueue: (() -> Void)?
    var playlistBrowseId: String? = nil
    var playlistOwned: Bool = false

    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
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
                        .font(.body.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.accentColor : .primary)
                        .lineLimit(1)
                    if !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
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
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            SongActionButtons(entry: entry, playlistBrowseId: playlistBrowseId, setVideoId: entry.setVideoId, playlistOwned: playlistOwned)
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            let playNext = PlatformSettings.shared.getBoolean(key: "swipe_to_play_next", default: false)
            if playNext {
                Button { (self.playNext ?? { controller.playNext(entry) })() } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.orange)
            } else {
                Button { (self.addToQueue ?? { controller.addToQueue(entry) })() } label: {
                    Label("Queue", systemImage: "text.badge.plus")
                }
                .tint(.blue)
            }
            if auth.signedIn, let vid = entry.videoId {
                Button {
                    Task { _ = await LibraryActions.rate(videoId: vid, status: LibraryActions.cachedLike(vid) == "LIKE" ? "INDIFFERENT" : "LIKE") }
                } label: {
                    Label(LibraryActions.cachedLike(vid) == "LIKE" ? "Unlike" : "Like", systemImage: LibraryActions.cachedLike(vid) == "LIKE" ? "heart.fill" : "heart")
                }
                .tint(.pink)
            }
            if !entry.isLocal {
                Button { DownloadStore.shared.download(entry) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.indigo)
            }
        }
        #endif
    }

    private var rowFill: Color {
        if active { return Color.primary.opacity(0.08) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }
}

/// Repeat glyph with a centred "1" when only the current track is looping —
/// the same differentiator Music uses on `repeat.1`.
struct RepeatGlyph: View {
    var mode: PlaybackController.RepeatMode
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            Image(.bchRepeat)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            if mode == .one {
                Text("1")
                    .font(.system(size: max(7, size * 0.42), weight: .bold, design: .rounded))
                    .offset(y: size * 0.02)
            }
        }
        .accessibilityLabel(mode == .one ? "Repeat one" : mode == .all ? "Repeat all" : "Repeat off")
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

import SwiftUI
import BitChordShared
import ImageIO
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
    /// The id of a track in a remote file library, when the picture may be inside
    /// its file rather than beside it.
    ///
    /// Nil for everything else and no task runs, so the common case — a YouTube row —
    /// costs one optional and a comparison. Carried here rather than resolved by each
    /// caller because this is the one view every surface draws a track through: the
    /// library page, the queue, the mini player and the player itself, which is
    /// upstream's list of `rememberRemoteArtworkUrl` callers as well.
    var remoteId: String?
    @State private var embedded: Data?

    init(entry: QueueEntry?, side: CGFloat? = nil) {
        self.init(
            url: entry?.thumbnailUrl,
            data: entry?.artworkData,
            side: side,
            remoteId: entry.flatMap { EmbeddedArtwork.trackId(of: $0) }
        )
    }

    init(url: String?, data: Data?, side: CGFloat? = nil, remoteId: String? = nil) {
        // Ask for the size the screen will actually draw at, on the screen's
        // actual scale. The old fixed `× 2` under-sampled every Retina row — a
        // 160pt card on a @3x display needs 480px and was being sent 320.
        let points = side ?? 300
        let scale = Double(PlatformScale.current)
        self.url = url.flatMap { SharedArtwork.sized($0, Int((points * scale).rounded())) }
        self.data = data
        self.side = side
        self.remoteId = remoteId
    }

    var body: some View {
        Group {
            artwork
        }
        .frame(width: side, height: side)
        .aspectRatio(1, contentMode: .fit)
        .background(.quaternary)
        .clipped()
        // No `.id()` here. Keying the subtree on the URL and byte count made
        // SwiftUI tear down and rebuild the whole image on every artwork change,
        // which showed up as a one-frame flicker on every track change. The
        // identity that matters is the row's, and the parent already has it.
        .accessibilityHidden(true)
        // Keyed on the track, so a row that scrolls round and comes back as a
        // different track re-resolves instead of showing the previous one's cover.
        .task(id: remoteId) {
            guard let remoteId else { return }
            embedded = await EmbeddedArtwork.embeddedCoverData(id: remoteId)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // Bytes already in hand win: a downloaded track's own artwork, and a remote
        // track's extracted cover once it has arrived.
        if let bytes = data ?? embedded, let image = Self.image(from: bytes) {
            scaled(image)
        } else if let url, let cached = ArtworkCache.shared.get(url) {
            scaled(cached)
        } else if let url {
            RemoteArtwork(url: url)
        } else {
            placeholder
        }
    }

    /// One drawing of a decoded image, for both platforms.
    ///
    /// A function rather than an `#if` between `Image(…)` and `.resizable()`: the
    /// compiler cannot see a base for the chain across a conditional compilation
    /// boundary, and a view builder that returns `some View` from two branches is the
    /// shape it wants anyway.
    @ViewBuilder
    private func scaled(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }

    private static func image(from data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
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

/// The backing scale of the screen being drawn on, so artwork is requested at
/// the pixel size it will actually be drawn at.
///
/// macOS windows move between displays of different scale factors — a window
/// dragged from a Retina laptop panel to an external 1x monitor would otherwise
/// keep asking the CDN for 2× artwork it no longer needs, and would look soft on
/// the way back if the request had been cached at the smaller size.
enum PlatformScale {
    static var current: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #else
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }
}

/// Memory + disk artwork cache — Apple stand-in for Coil's LRU.
///
/// ## Why the disk read is off the main thread
///
/// This used to be `@MainActor` with a synchronous `get(_:)` that did
/// `Data(contentsOf:)` plus an image decode inline, and it was called straight
/// from `ArtworkView.body` for every visible row. On a cold cache, scrolling a
/// 500-row library meant hundreds of file reads and image decodes on the main
/// thread — dropped frames, with the scroll gesture stuttering under it.
///
/// So the cache itself is no longer actor-isolated: the memory tier is an
/// `NSCache`, which is thread-safe by contract, and the disk tier is read on a
/// background executor. `get(_:)` still returns synchronously for the common
/// warm case (a memory hit) and returns nil for a cold one, which drops straight
/// through to [RemoteArtwork]'s async path — so the first paint of a cold row is
/// no slower than before, and every subsequent one is a memory hit.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, PlatformImage>()
    private let folder = DiskCache.cachesSubfolder("images")
    private static let diskLimit: Int64 = 128 * 1024 * 1024
    /// Serialises cold disk reads so a fast scroll does not queue hundreds of
    /// concurrent file reads for images that have already scrolled away.
    private let readQueue = DispatchQueue(
        label: "BitChord.artwork-disk",
        qos: .userInitiated
    )

    init() {
        memory.totalCostLimit = 48 * 1024 * 1024
        memory.countLimit = 400
    }

    /// The warm path. A memory hit returns immediately; a miss returns nil and
    /// the caller falls back to its async load, which populates both tiers.
    private func cacheKey(_ url: String) -> String {
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: url)
        return PageRepository.digest(url + headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\u{0}"))
    }
    func get(_ url: String) -> PlatformImage? {
        memory.object(forKey: cacheKey(url) as NSString)
    }

    /// Synchronous disk read, for the rare caller that genuinely needs the bytes
    /// before it can lay out. Off the main thread by construction.
    func getBlocking(_ url: String) -> PlatformImage? {
        if let hit = get(url) { return hit }
        var resolved: PlatformImage?
        readQueue.sync {
            resolved = readFromDisk(url)
        }
        return resolved
    }

    private static func decode(_ data: Data, url: String) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let requested: Int
        if let range = url.range(of: #"w\d+-h\d+"#, options: .regularExpression) {
            requested = min(2048, max(64, Int(url[range].dropFirst().split(separator: "-").first ?? "1200") ?? 1200))
        } else { requested = 1200 }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: requested,
            kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private func imageCost(_ image: PlatformImage) -> Int {
        #if os(iOS)
        return (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    private func readFromDisk(_ url: String) -> PlatformImage? {
        let file = diskURL(url)
        guard let data = try? Data(contentsOf: file), let image = Self.decode(data, url: url) else { return nil }
        memory.setObject(image, forKey: cacheKey(url) as NSString, cost: imageCost(image))
        return image
    }

    func load(_ url: String) async -> PlatformImage? {
        if let hit = get(url) { return hit }
        let onDisk = await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
            readQueue.async { [weak self] in cont.resume(returning: self?.readFromDisk(url)) }
        }
        if let onDisk { return onDisk }
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: url)
        let key = cacheKey(url)
        guard let data = await ArtworkRequests.shared.data(url: url, headers: headers), !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            readQueue.async { [weak self] in
                guard let self, key == self.cacheKey(url), let image = Self.decode(data, url: url) else {
                    continuation.resume(returning: nil); return
                }
                self.memory.setObject(image, forKey: key as NSString, cost: self.imageCost(image))
                try? data.write(to: self.diskURL(url), options: .atomic)
                // Trim per batch, rather than walking the folder after every tile.
                if Date().timeIntervalSince(self.lastTrim) > 60 {
                    self.lastTrim = Date()
                    DiskCache.trimFolder(self.folder, limitBytes: Self.diskLimit)
                }
                continuation.resume(returning: image)
            }
        }
    }
    private var lastTrim = Date.distantPast

    func clear() {
        memory.removeAllObjects()
        DiskCache.clearFolder(folder)
    }

    private func diskURL(_ url: String) -> URL {
        folder.appendingPathComponent(cacheKey(url))
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
    var cornerRadius: CGFloat = Theme.Metrics.rowRadius
    @State private var phase: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(height: height)
            // A skeleton that still pulses is still motion. With Reduce Motion on
            // it is a static placeholder, which is what the setting is asking for.
            .opacity(reduceMotion ? 0.75 : (phase ? 0.5 : 0.9))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: phase
            )
            .onAppear { phase = true }
            .accessibilityHidden(true)
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
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hovering = false

    /// How many lines a track's text may take.
    ///
    /// One at ordinary sizes, because this is the most-repeated row in the app and
    /// a list of wrapping rows is a list nobody can scan. Two once the reader has
    /// asked for larger text: a row that truncates harder as somebody needs it more
    /// is the opposite of what the setting is for, and this is where that shows
    /// first — a long title is exactly what stops being readable.
    private var titleLines: Int? { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

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
                        .lineLimit(titleLines)
                    if !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(titleLines)
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
                    .decorative()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.rowRadius, style: .continuous)
                .fill(rowFill)
        }
        .onHover { hovering = $0 }
        // One stop per row, not four. Title, artist, duration and chevron read as
        // separate elements otherwise, so a screen-reader user had to swipe four
        // times to hear one track — and the artwork announced its asset name on
        // top of that.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
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
                    // Through the controller, so this row's heart reports a
                    // refusal the same way the player's does. It used to call
                    // `rate` directly and discard the answer.
                    controller.toggleLike(videoId: vid)
                } label: {
                    Label(LibraryActions.cachedLike(vid) == "LIKE" ? "Unlike" : "Like", systemImage: LibraryActions.cachedLike(vid) == "LIKE" ? "heart.fill" : "heart")
                }
                .tint(.pink)
            }
            if !entry.isLocal {
                Button {
                    switch DownloadStore.shared.download(entry) {
                    case .started:
                        toast.show("Downloading \(entry.title)")
                    case .blockedByWifiOnly:
                        toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                    case .alreadyExists:
                        toast.show("\(entry.title) is already downloading or downloaded", kind: .info)
                    case .ignoredLocalTrack:
                        break
                    }
                } label: {
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

    /// One sentence for the whole row, in the order a person would say it.
    private var accessibilityLabel: String {
        var parts = [entry.title]
        if !entry.artist.isEmpty { parts.append(entry.artist) }
        if let duration = entry.durationText, !duration.isEmpty { parts.append(duration) }
        if buffering { parts.append("Buffering") }
        return parts.joined(separator: ", ")
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

/// Upstream `ThinSlider.kt` — hairline capsule, Automix window marker, mix sheen.
///
/// Hand-drawn rather than a `Slider` because a native one cannot show the Automix
/// transition window or the mix sheen behind the playhead. That is a fair trade
/// only if the control then behaves like a slider to assistive technology, which
/// it did not: it published an `accessibilityValue` with no label and no
/// adjustable action, so a VoiceOver user could not seek at all.
struct ThinSlider: View {
    let value: Double
    let maximum: Double
    var label: String = "Playback position"
    var mixing: Bool = false
    var transitionWindow: ClosedRange<Double>? = nil
    var onEditingChanged: (Double) -> Void
    var onDraggingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var dragValue: Double?

    private var current: Double { dragging ? (dragValue ?? value) : value }

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return min(max(current / maximum, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let height: CGFloat = dragging ? 12 : 7
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.26))
                if !dragging, let window = transitionWindow, window.upperBound > window.lowerBound {
                    let from = geo.size.width * window.lowerBound
                    let to = geo.size.width * window.upperBound
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: max(0, to - from))
                        .offset(x: from)
                }
                if fraction > 0 && !(mixing && !dragging) {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: max(height, geo.size.width * fraction))
                }
                if mixing && !dragging {
                    MixSheenBar()
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { onDraggingChanged(true) }
                        dragging = true
                        let f = min(max(g.location.x / geo.size.width, 0), 1)
                        dragValue = f * maximum
                    }
                    .onEnded { _ in
                        if let v = dragValue { onEditingChanged(v) }
                        dragging = false
                        dragValue = nil
                        onDraggingChanged(false)
                    }
            )
            .animation(Motion.once(reduceMotion, duration: 0.28, curve: .spring(response: 0.28, dampingFraction: 0.72)), value: dragging)
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(NowPlayingView.timestamp(current))
        // One second per increment, five seconds per decrement, matching what
        // Music does and what a seek bar is expected to feel like when driven from
        // a screen reader rather than a drag.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onEditingChanged(min(maximum, current + 1))
            case .decrement: onEditingChanged(max(0, current - 5))
            @unknown default: break
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

private struct MixSheenBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The sheen is a 30fps animated band crossing the playhead to show an
        // Automix transition in progress. With Reduce Motion on it would be the
        // single most active thing on screen, so it is replaced by a static tint
        // that still reads as "something is happening here".
        if reduceMotion {
            Capsule().fill(Color.white.opacity(0.22))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let period = 0.5
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: period) / period
                    let band = size.width * 0.7
                    let centre = -band + (size.width + band * 2) * phase
                    let gradient = Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.95), location: 0.5),
                        .init(color: .clear, location: 1),
                    ])
                    context.fill(
                        Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: centre - band / 2, y: 0),
                            endPoint: CGPoint(x: centre + band / 2, y: 0)
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Transport haptics — upstream `Haptics.kt`, respecting system settings.
enum PlaylistPinning {
    static let maxPins = 5

    static func pinnedIds() -> [String] {
        PlatformSettings.shared.getString(key: "pinned_playlists", default: "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Returns false when a sixth pin would be added — caller should toast.
    @discardableResult
    static func toggle(browseId: String) -> Bool {
        let before = pinnedIds()
        if !before.contains(browseId), before.count >= maxPins { return false }
        return AppSettings.shared.togglePinnedPlaylist(browseId: browseId) || before.contains(browseId)
    }
}

@MainActor
enum PlayerParity {
    static func mixInProgress(_ controller: PlaybackController) -> Bool {
        controller.smartMixInProgress
    }

    static func transitionWindow(_ controller: PlaybackController) -> ClosedRange<Double>? {
        guard let w = controller.smartTransitionWindow, w.end > w.start else { return nil }
        return w.start...w.end
    }

    static func sleepStatus(_ controller: PlaybackController) -> String? {
        controller.sleepTimerStatus
    }

    static func debugLog(_ controller: PlaybackController) -> String {
        let dump = controller.debugLogText
        return dump.isEmpty ? "No debug lines yet." : dump
    }

    static func lyricsSourceLabel(_ controller: PlaybackController) -> String? {
        guard let label = controller.lyricsSourceLabel, !label.isEmpty else { return nil }
        return label
    }

    static func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum LyricsSourceNames {
    /// The order the shared module asks sources in, with the current enabled set.
    ///
    /// Read from `AppSettings` rather than listed here. The host used to carry
    /// its own list of source names, and every source added since went into the
    /// enum and not into it — so this default was quietly a different set from
    /// the real one, and the *only* thing it was used for was the first read,
    /// before the shared module had been asked.
    static var defaultOrder: [String] {
        LyricsSourceCatalog.names()
    }

    static var defaultEnabled: String { defaultOrder.joined(separator: ",") }

    static func canonical(_ id: String) -> String {
        switch id.trimmingCharacters(in: .whitespaces) {
        case "PLUS": "LYRICS_PLUS"
        case "BETTER": "BETTER_LYRICS"
        case "SIMP": "SIMP_MUSIC"
        default: id
        }
    }

    static func normalizeList(_ raw: String) -> String {
        raw.split(separator: ",").map { canonical(String($0)) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    /// The display name, from the shared module.
    ///
    /// A table here was a third copy of the same fact, and the one place it
    /// mattered most — what a source is called in the list — was the copy least
    /// likely to be updated.
    static func label(_ id: String) -> String {
        LyricsSourceCatalog.label(for: canonical(id)) ?? canonical(id)
    }
}

/// The shared lyrics catalogue, decoded once.
enum LyricsSourceCatalog {
    private struct Entry: Decodable {
        let name: String
        let label: String
    }

    private static let entries: [Entry] = {
        guard let data = AppSettings.shared.lyricsSourceCatalogJson().data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }()

    static func names() -> [String] { entries.map(\.name) }

    static func label(for name: String) -> String? {
        entries.first { $0.name == name }?.label
    }
}

actor ArtworkRequests {
    static let shared = ArtworkRequests()
    private var flights: [String: Task<Data?, Never>] = [:]
    func data(url: String, headers: [String: String]) async -> Data? {
        let key = PageRepository.digest(url + headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined())
        if let task = flights[key] { return await task.value }
        let task = Task<Data?, Never> {
            guard let endpoint = URL(string: url) else { return nil }
            var request = URLRequest(url: endpoint)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            return try? await GuardedHTTP.shared.data(for: request)
        }
        flights[key] = task
        let data = await task.value
        flights.removeValue(forKey: key)
        return data
    }
}

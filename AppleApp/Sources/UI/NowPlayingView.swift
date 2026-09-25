import SwiftUI
import BitChordShared
import AVKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Full Now Playing (UI spec §3.3). On macOS this *is* the window: traffic
/// lights stay, close / volume / AirPlay live in the real toolbar, and the
/// wash shows through a hidden title. On iPhone it is a swipe-to-dismiss
/// sheet that zooms from the mini player; on iPad a page-sized sheet.
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthController.self) private var auth
    @State private var pane: PlayerPane = .lyrics

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // ---- macOS: window-root player -----------------------------------------
    #if os(macOS)
    private var macOSBody: some View {
        ZStack {
            MeshBackdrop(seed: controller.current?.id.hashValue ?? 0, artwork: controller.current?.artworkData)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 8) {
                leftColumn
                    .frame(width: 420)
                rightColumn
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
            .padding(.bottom, 16)

            VStack {
                Spacer()
                    .allowsHitTesting(false)
                HStack {
                    Spacer()
                        .allowsHitTesting(false)
                    HStack(spacing: 8) {
                        GlassCircleButton(icon: .bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                            Haptics.play(.expand)
                            pane = .lyrics
                        }
                        .help("Lyrics")
                        GlassCircleButton(icon: .bchQueue, selected: pane == .queue, label: "Up Next") {
                            Haptics.play(.expand)
                            pane = .queue
                        }
                        .help("Up Next")
                    }
                    .padding(.trailing, 22)
                    .padding(.bottom, 18)
                }
            }
        }
        .toolbar { macPlayerToolbar }
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .environment(\.colorScheme, .dark)
    }

    @ToolbarContentBuilder
    private var macPlayerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Close", systemImage: "xmark") {
                appModel.nowPlayingPresented = false
            }
            .labelStyle(.iconOnly)
            .help("Close")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        if !controller.hideVolumeBar {
            ToolbarItem {
                ToolbarVolumeSlider(volume: Binding(
                    get: { controller.volume },
                    set: { controller.volume = $0 }
                ))
                .help("Volume")
            }
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
            ToolbarSpacer(.fixed)
        }

        if #available(macOS 26.0, *) {
            ToolbarItem {
                AirPlayRouteButton()
                    .frame(width: 22, height: 22)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: Circle())
                    .help("AirPlay")
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem {
                AirPlayRouteButton()
                    .frame(width: 22, height: 22)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .help("AirPlay")
            }
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HeroArtwork(
                entry: controller.current,
                canvasURL: controller.canvasURL,
                fallbackURL: controller.canvasFallbackURL,
                isPlaying: controller.isPlaying
            )
            .id(controller.current?.id)

            VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.current?.title ?? "Nothing playing")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    Text(creditLine)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
                Spacer(minLength: 8)
                if auth.signedIn, controller.current?.videoId != nil {
                    GlassCircleButton(icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                                      label: controller.isLiked ? "Remove Like" : "Like") {
                        controller.toggleLike()
                    }
                    .help(controller.isLiked ? "Remove from Liked Music" : "Like")
                }
                moreMenu
            }

            positionControls
            playerTransport
            if PlatformSettings.shared.getBoolean(key: "show_nerd_stats", default: false) {
                if let nerd = controller.nerd, !nerd.codec.isEmpty {
                    Text(nerdLine(nerd))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                } else if controller.racingLossless {
                    Text("Upgrading Quality")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 12)
            }
            .padding(.horizontal, 36)
            .padding(.top, 4)
        }
    }

    private var rightColumn: some View {
        Group {
            switch pane {
            case .lyrics:
                LyricsPane(
                    lines: controller.displayedLyrics,
                    loading: controller.lyricsLoading,
                    position: controller.position,
                    hasTrack: controller.current != nil,
                    sourceLabel: controller.lyricsSourceLabel,
                    onSeek: { controller.seek(to: $0) },
                    translator: controller.lyricsTranslator,
                    trackId: controller.current?.id ?? ""
                )
            case .queue:
                UpNextPane()
            }
        }
        .padding(.trailing, 28)
        .padding(.leading, 8)
        .padding(.bottom, 56)
    }

    private var creditLine: String {
        let artist = controller.current?.artist ?? ""
        let album = controller.current?.albumName ?? ""
        if artist.isEmpty { return album }
        if album.isEmpty { return artist }
        return "\(artist) — \(album)"
    }
    #endif

    // ---- iOS sheet ----------------------------------------------------------
    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            ZStack {
                MeshBackdrop(seed: controller.current?.id.hashValue ?? 0, artwork: controller.current?.artworkData)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    HeroArtwork(
                        entry: controller.current,
                        canvasURL: controller.canvasURL,
                        fallbackURL: controller.canvasFallbackURL,
                        isPlaying: controller.isPlaying
                    )
                    .id(controller.current?.id)
                    VStack(spacing: 16) {
                        VStack(spacing: 6) {
                            Text(controller.current?.title ?? "Nothing playing")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                            Text(controller.current?.artist ?? "")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.75))
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        }
                        positionControls
                            .padding(.horizontal, 32)
                        if PlatformSettings.shared.getBoolean(key: "show_nerd_stats", default: false) {
                            if let nerd = controller.nerd, !nerd.codec.isEmpty {
                                Text(nerdLine(nerd))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.7))
                            } else if controller.racingLossless {
                                Text("Upgrading Quality")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        playerTransport
                        Group {
                            switch pane {
                            case .lyrics:
                                LyricsPane(
                                    lines: controller.displayedLyrics,
                                    loading: controller.lyricsLoading,
                                    position: controller.position,
                                    hasTrack: controller.current != nil,
                                    sourceLabel: controller.lyricsSourceLabel,
                                    onSeek: { controller.seek(to: $0) },
                                    translator: controller.lyricsTranslator,
                                    trackId: controller.current?.id ?? ""
                                )
                            case .queue:
                                UpNextPane()
                            }
                        }
                        .frame(maxHeight: 220)
                        Spacer(minLength: 20)
                    }
                }
                VStack {
                    HStack {
                        Spacer()
                        if auth.signedIn, controller.current?.videoId != nil {
                            GlassCircleButton(icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                                      label: controller.isLiked ? "Remove Like" : "Like") {
                                controller.toggleLike()
                            }
                        }
                        GlassCircleButton(icon: .bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                            Haptics.play(.expand)
                            pane = .lyrics
                        }
                        GlassCircleButton(icon: .bchQueue, selected: pane == .queue, label: "Up Next") {
                            Haptics.play(.expand)
                            pane = .queue
                        }
                        moreMenu
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    Spacer()
                }
            }
            .toolbar { playerToolbar }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if #available(iOS 26.0, *) {
                Button(role: .close) { dismiss() }
            } else {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            AirPlayRouteButton()
                .frame(width: 22, height: 22)
                .help("AirPlay")
        }
    }
    #endif

    // ---- Shared pieces ------------------------------------------------------

    private var positionControls: some View {
        VStack(spacing: 6) {
            ThinSlider(
                value: controller.position,
                maximum: controller.duration,
                mixing: controller.smartMixInProgress,
                transitionWindow: controller.smartTransitionWindow.flatMap { w in
                    w.end > w.start ? w.start...w.end : nil
                }
            ) { controller.seek(to: $0) }
            .tint(.white)

            HStack {
                Text(Self.timestamp(controller.position))
                Spacer()
                Text(remainingLabel)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
    }

    private var remainingLabel: String {
        guard controller.duration > 0 else { return "-0:00" }
        return "-\(Self.timestamp(max(0, controller.duration - controller.position)))"
    }

    /// Music's order: shuffle · previous · play-in-circle · next · repeat.
    /// Play sits on a white disc so it never disappears into a bright wash.
    /// The transport row.
    ///
    /// Every control carries an explicit `accessibilityLabel` as well as a
    /// `.help()`. The help text is macOS-only, so on iOS these were unlabelled
    /// template images and VoiceOver announced the asset name — "bch shuffle,
    /// button" — rather than what the button does. The labels are the same
    /// strings, so the two platforms say the same thing.
    private var playerTransport: some View {
        HStack(spacing: 28) {
            Button {
                Haptics.play(controller.shuffleEnabled ? .toggleOff : .toggleOn)
                controller.toggleShuffle()
            } label: {
                Image(.bchShuffle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.shuffleEnabled ? .white : .white.opacity(0.72))
            .help(controller.shuffleEnabled ? "Shuffle on" : "Shuffle off")
            .accessibilityLabel(controller.shuffleEnabled ? "Shuffle on" : "Shuffle off")

            Button {
                Haptics.play(.skipPrevious)
                controller.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayPrevious)
            .help("Previous")
            .accessibilityLabel("Previous track")

            Button {
                Haptics.play(controller.isPlaying ? .pause : .resume)
                controller.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                    if controller.isBuffering {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.black)
                    } else {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: controller.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .disabled(controller.current == nil && !controller.isBuffering)
            .help(controller.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(controller.isBuffering ? "Buffering" : (controller.isPlaying ? "Pause" : "Play"))

            Button {
                Haptics.play(.skipNext)
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayNext)
            .help("Next")
            .accessibilityLabel("Next track")

            Button {
                Haptics.play(.select)
                controller.cycleRepeat()
            } label: {
                RepeatGlyph(mode: controller.repeatMode, size: 18)
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.repeatMode == .off ? .white.opacity(0.72) : .white)
            .help(controller.repeatMode == .one ? "Repeat one" : controller.repeatMode == .all ? "Repeat all" : "Repeat off")
            .accessibilityLabel(repeatLabel)
        }
        .foregroundStyle(.white)
    }

    private var repeatLabel: String {
        switch controller.repeatMode {
        case .one: "Repeat one"
        case .all: "Repeat all"
        case .off: "Repeat off"
        }
    }

    private var moreMenu: some View {
        Menu {
            if let current = controller.current {
                SongActionButtons(entry: current, showSleepTimer: true, showDebugLog: true)
                Divider()
            }
            Button("Download") { controller.downloadCurrent() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .help("More")
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        let hours = mins / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins % 60, secs)
            : String(format: "%d:%02d", mins, secs)
    }

    private func nerdLine(_ nerd: NerdStatsRec) -> String {
        var parts = [nerd.codec]
        if nerd.kbps > 0 { parts.append("\(nerd.kbps) kbps") }
        if nerd.bitDepth > 0 { parts.append("\(nerd.bitDepth)-bit") }
        if nerd.sampleRate > 0 { parts.append("\(nerd.sampleRate) Hz") }
        if nerd.channels > 0 { parts.append("\(nerd.channels) ch") }
        if let current = controller.current {
            if current.isLocal {
                parts.append("Local")
            } else if current.source.hasPrefix("yt:") {
                parts.append("YouTube")
            } else if !current.source.isEmpty {
                parts.append(current.source)
            }
        }
        if controller.racingLossless { parts.append("Upgrading Quality") }
        if let tier = controller.analysisTier, !tier.isEmpty { parts.append(tier) }
        if let conf = controller.analysisConfidence { parts.append(String(format: "%.0f%% mix", conf * 100)) }
        if controller.smartMixInProgress { parts.append("Automix") }
        return parts.joined(separator: " · ")
    }
}

private enum PlayerPane {
    case lyrics, queue
}

/// Frosted circular chrome used for dismiss / lyrics / queue.
/// A round, material-backed icon button for the player's secondary controls.
///
/// [label] is required rather than optional: every one of these is an
/// icon-only button, and without it VoiceOver announced the asset name. The
/// glyphs are upstream's own, per UI spec §6.
struct GlassCircleButton: View {
    var system: String? = nil
    var icon: ImageResource? = nil
    var selected: Bool = false
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).resizable().scaledToFit().frame(width: 15, height: 15)
                } else if let system {
                    Image(systemName: system).font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(.white.opacity(selected ? 0.28 : 0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// Soft shadow so white glyphs stay readable on a bright artwork wash.
    func playerGlyph() -> some View {
        shadow(color: .black.opacity(0.55), radius: 5, y: 1)
    }
}

/// Music's Up Next column: AutoPlay / AutoMix pills, then upcoming rows split
/// into manual vs AutoPlay — a drag never crosses that boundary.
private struct UpNextPane: View {
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                autoPill(
                    title: "AutoPlay",
                    on: controller.autoplayEnabled
                ) {
                    Haptics.play(controller.autoplayEnabled ? .toggleOff : .toggleOn)
                    controller.toggleAutoplay()
                }
                autoPill(
                    title: "AutoMix",
                    on: controller.automixEnabled
                ) {
                    Haptics.play(controller.automixEnabled ? .toggleOff : .toggleOn)
                    controller.toggleAutomix()
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Playing")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if !manualUpcoming.isEmpty || !autoplayUpcoming.isEmpty {
                    Button("Clear") { controller.clearUpcoming() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if manualUpcoming.isEmpty && autoplayUpcoming.isEmpty {
                Text("Nothing else queued. Turn on AutoPlay to keep the music going.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 8)
                Spacer()
            } else {
                List {
                    if !manualUpcoming.isEmpty {
                        ForEach(manualUpcoming) { item in
                            queueRow(item)
                        }
                        .onMove { source, dest in
                            move(source, dest, rows: manualUpcoming)
                        }
                        .onDelete { offsets in
                            remove(offsets, rows: manualUpcoming)
                        }
                    }
                    if showAutoplayHeading {
                        Section {
                            if autoplayUpcoming.isEmpty {
                                Text("Similar music will keep playing")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(autoplayUpcoming) { item in
                                    queueRow(item)
                                }
                                .onMove { source, dest in
                                    move(source, dest, rows: autoplayUpcoming)
                                }
                                .onDelete { offsets in
                                    remove(offsets, rows: autoplayUpcoming)
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(.bchInfinity)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .foregroundStyle(.white.opacity(0.75))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("AutoPlay")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                    Text(autoplayUpcoming.isEmpty
                                         ? "Similar music will keep playing"
                                         : "Similar music, picked to follow on")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                // A real edit mode with an explicit control, rather than
                // `.constant(.active)`. Forcing it active showed a red delete
                // circle on every row permanently and suppressed the system
                // Edit/Done toggle, so there was no way back out of it — and it
                // fought the one gesture people already expect here, which is
                // swipe-to-delete. Reordering is still available from the Reorder
                // state; deletion is available at all times by swiping.
                //
                // iOS-only because `EditMode` is. On macOS the queue is reordered
                // by click-to-move, which is the platform's own idiom.
                .environment(\.editMode, $editMode)
                .toolbar {
                    if manualUpcoming.count > 1 {
                        ToolbarItem(placement: .automatic) {
                            Button(editMode == .active ? "Done" : "Reorder") {
                                withAnimation {
                                    editMode = editMode == .active ? .inactive : .active
                                }
                            }
                        }
                    }
                }
                #endif
            }
        }
        .padding(.top, 8)
    }

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    private var autoplayStart: Int { controller.autoplaySectionStart }

    /// Upcoming manual rows — never includes AutoPlay, never the playing track.
    private var manualUpcoming: [QueueRow] {
        rows(in: controller.firstMovableQueueIndex..<autoplayStart)
    }

    private var autoplayUpcoming: [QueueRow] {
        rows(in: autoplayStart..<controller.queue.count)
    }

    private var showAutoplayHeading: Bool {
        controller.autoplayEnabled || !autoplayUpcoming.isEmpty
    }

    private func rows(in range: Range<Int>) -> [QueueRow] {
        guard range.lowerBound < range.upperBound else { return [] }
        return range.compactMap { index in
            guard controller.queue.indices.contains(index) else { return nil }
            return QueueRow(index: index, entry: controller.queue[index])
        }
    }

    private var subtitle: String {
        let artist = controller.current?.artist ?? ""
        if !autoplayUpcoming.isEmpty {
            return artist.isEmpty ? "Similar artists" : "From \(artist) & Similar Artists"
        }
        let n = manualUpcoming.count
        if n == 0 { return "Nothing queued" }
        return n == 1 ? "1 song" : "\(n) songs"
    }

    private func queueRow(_ item: QueueRow) -> some View {
        Button {
            controller.playQueueItem(at: item.index)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(entry: item.entry, side: 40)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entry.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.entry.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.04))
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Play") { controller.playQueueItem(at: item.index) }
            Button("Remove from Queue", role: .destructive) {
                controller.removeFromQueue(at: IndexSet(integer: item.index))
            }
        }
    }

    private func move(_ source: IndexSet, _ dest: Int, rows: [QueueRow]) {
        guard let fromLocal = source.first, rows.indices.contains(fromLocal) else { return }
        let fromQueue = rows[fromLocal].index
        let clampedDest = min(max(dest, 0), rows.count)
        let toQueue: Int
        if clampedDest >= rows.count {
            toQueue = (rows.last?.index ?? fromQueue) + 1
        } else {
            toQueue = rows[clampedDest].index
        }
        controller.moveQueue(from: IndexSet(integer: fromQueue), to: toQueue)
    }

    private func remove(_ offsets: IndexSet, rows: [QueueRow]) {
        let indices = IndexSet(offsets.compactMap { rows.indices.contains($0) ? rows[$0].index : nil })
        controller.removeFromQueue(at: indices)
    }

    private func autoPill(title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(.bchInfinity)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(on ? 0.28 : 0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "\(title) on" : "\(title) off")
    }
}

private struct QueueRow: Identifiable {
    let index: Int
    let entry: QueueEntry
    var id: String { "\(index)-\(entry.id)" }
}

/// Square sleeve: still art, motion canvas cropped to fill, Apple Music pause
/// shrink inside a fixed slot so the column does not reflow. Used when the
/// full-bleed banner is off.
private struct SleeveArt: View {
    var entry: QueueEntry?
    var canvasURL: URL?
    var fallbackURL: URL? = nil
    var isPlaying: Bool
    var side: CGFloat

    var body: some View {
        ZStack {
            ArtworkView(entry: entry, side: side)
            if let canvasURL {
                CanvasPlayer(url: canvasURL, fallbackURL: fallbackURL, isPlaying: isPlaying)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .scaleEffect(isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.85, dampingFraction: 0.75), value: isPlaying)
        .frame(width: side, height: side)
    }
}

/// Upstream's full-bleed banner (`NowPlayingScreen` heroMode): the cover is
/// cropped to fill, and the bottom 42% dissolves into the mesh. That dissolve
/// is the artwork "effect" — not a warp of the pixels. A motion clip, when
/// one exists, plays in the same frame with the same mask.
private struct HeroArtwork: View {
    var entry: QueueEntry?
    var canvasURL: URL?
    var fallbackURL: URL? = nil
    var isPlaying: Bool

    private let fadeFraction: CGFloat = 0.42

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArtworkView(entry: entry, side: max(geo.size.width, geo.size.height))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                if let canvasURL {
                    CanvasPlayer(url: canvasURL, fallbackURL: fallbackURL, isPlaying: isPlaying)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .compositingGroup()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 1 - fadeFraction),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

/// Upstream `MeshGradientBackground`: four luminous radial blobs sampled from
/// the sleeve, blurred into a wash. Not SwiftUI `MeshGradient` — that warps a
/// vertex grid and is what tore the artwork's edges. Blobs drift once on a
/// track change, then rest.
struct MeshBackdrop: View {
    var seed: Int
    var artwork: Data? = nil

    @State private var phase: Double = 0
    @State private var base: Color = .black
    @State private var blob0 = Color.clear
    @State private var blob1 = Color.clear
    @State private var blob2 = Color.clear
    @State private var blob3 = Color.clear

    private var reduceBlur: Bool {
        PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    }
    private var reduceAnimation: Bool {
        PlatformSettings.shared.getBoolean(key: "reduce_animation", default: false)
    }

    var body: some View {
        let blobs = [blob0, blob1, blob2, blob3]
        Canvas { context, size in
            let anchors: [(CGFloat, CGFloat)] = [
                (0.20, 0.25), (0.80, 0.20), (0.75, 0.80), (0.25, 0.75),
            ]
            let speeds: [Double] = [1, -0.7, 0.85, -1.15]
            let radius = max(size.width, size.height) * 0.62
            for i in 0..<4 {
                let color = blobs[i]
                let x = (anchors[i].0 + 0.16 * cos(phase * speeds[i] + Double(i) * 1.7)) * size.width
                let y = (anchors[i].1 + 0.16 * sin(phase * speeds[i] * 0.9 + Double(i) * 2.3)) * size.height
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(0.85), color.opacity(0)]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Color.black.opacity(0.10), Color.black.opacity(0.38)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        .background(base)
        .blur(radius: reduceBlur ? 0 : 64)
        .scaleEffect(1.3)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { settle(seed: seed, artwork: artwork, first: true) }
        .onChange(of: seed) { _, new in settle(seed: new, artwork: artwork, first: false) }
        .onChange(of: artwork) { _, data in apply(ArtworkPalette.meshBlobs(from: data, seed: seed), animated: true) }
    }

    private func settle(seed: Int, artwork: Data?, first: Bool) {
        apply(ArtworkPalette.meshBlobs(from: artwork, seed: seed), animated: !first)
        guard !reduceAnimation else { return }
        withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 8)) {
            phase += .pi * 0.45
        }
    }

    private func apply(_ mesh: ArtworkPalette.MeshBlobs, animated: Bool) {
        let run = {
            base = mesh.base
            blob0 = mesh.blobs[0]
            blob1 = mesh.blobs[1]
            blob2 = mesh.blobs[2]
            blob3 = mesh.blobs[3]
        }
        if animated && !reduceAnimation {
            withAnimation(.easeInOut(duration: 1.4), run)
        } else {
            run()
        }
    }
}

/// Upstream's lyrics strip: the current line is bright and sharp; neighbours
/// recede by opacity, the same treatment as the Android panel.
struct LyricsPane: View {
    var lines: [LyricLineDto]
    var loading: Bool
    var position: Double
    var hasTrack: Bool
    var sourceLabel: String? = nil
    var onSeek: ((Double) -> Void)? = nil
    /// Absent where the caller has no track to translate, which is the case that
    /// matters: an empty lyric has nothing to translate and offering the control
    /// anyway is an invitation to a request that cannot succeed.
    var translator: LyricsTranslator?
    var trackId: String = ""

    private var activeIndex: Int {
        let ms = Swift.Int64(position * 1000)
        return lines.lastIndex { $0.timeMs <= ms } ?? 0
    }

    var body: some View {
        Group {
            if !hasTrack {
                Text("Play a song to see lyrics here.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            } else if loading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else if lines.isEmpty {
                Text("No lyrics for this track.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let credit = attribution {
                        Text(credit)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.10), in: Capsule())
                            .padding(.horizontal, 12)
                    }
                    if let translator {
                        LyricsTranslationNote(outcome: translator.outcome)
                            .padding(.horizontal, 12)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    WordSyncedLine(
                                        line: line,
                                        active: index == activeIndex,
                                        distance: abs(index - activeIndex),
                                        position: position
                                    )
                                    .id(index)
                                    .contentShape(.rect)
                                    .onTapGesture {
                                        onSeek?(Double(line.timeMs) / 1000.0)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.never)
                        .onChange(of: activeIndex) { _, index in
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attribution: String? {
        guard let sourceLabel, !sourceLabel.isEmpty else { return nil }
        return "Lyrics by \(sourceLabel)"
    }
}

private struct WordSyncedLine: View {
    let line: LyricLineDto
    let active: Bool
    let distance: Int
    let position: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(leadRendered)
                .font(.title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: active ? .white.opacity(0.35) : .clear, radius: active ? 8 : 0, y: 0)
                .scaleEffect(active ? 1.04 : 1, anchor: .leading)
            if let backing = backingRendered {
                Text(backing)
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.45)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: active)
        .animation(.easeInOut(duration: 0.12), value: Int(position * 10))
    }

    private var split: (lead: String, backing: String?) {
        if let background = line.background, !background.text.isEmpty {
            return (line.text, background.text)
        }
        return Self.splitBackground(line.text)
    }

    private var leadRendered: AttributedString {
        render(text: split.lead, words: leadWords, glowing: active)
    }

    private var backingRendered: AttributedString? {
        if let background = line.background, !background.text.isEmpty {
            return render(text: background.text, words: background.words, glowing: false)
        }
        guard let backing = split.backing, !backing.isEmpty else { return nil }
        return render(text: backing, words: backingWords, glowing: false)
    }

    private var leadWords: [LyricWordDto] {
        if line.background != nil { return line.words }
        return line.words.filter { !Self.isBackingToken($0.text) }
    }

    private var backingWords: [LyricWordDto] {
        line.words.filter { Self.isBackingToken($0.text) }
    }

    private func render(text: String, words: [LyricWordDto], glowing: Bool) -> AttributedString {
        if words.isEmpty {
            var s = AttributedString(text.isEmpty ? "♪" : text)
            s.font = .title.weight(active ? .bold : .regular)
            s.foregroundColor = Color.white.opacity(active ? 1 : max(0.22, 0.55 - Double(distance) * 0.12))
            return s
        }
        let ms = Swift.Int64(position * 1000)
        var result = AttributedString()
        for (i, word) in words.enumerated() {
            var run = AttributedString(word.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))
            let sung = ms >= word.startMs
            let current = sung && ms < word.endMs
            run.font = .title.weight(current ? .bold : .regular)
            if glowing && current {
                run.foregroundColor = Color.white
                run.underlineStyle = .single
            } else {
                run.foregroundColor = Color.white.opacity(sung ? 1 : 0.38)
            }
            result.append(run)
            if i < words.count - 1 {
                result.append(AttributedString(" "))
            }
        }
        return result
    }

    private static func isBackingToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("(") || trimmed.hasSuffix(")")
    }

    /// Display-only split matching upstream `withBackgroundVocals`.
    static func splitBackground(_ text: String) -> (lead: String, backing: String?) {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), close > open else {
            return (text, nil)
        }
        let inner = text[text.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return (text, nil) }
        let lead = (text[..<open] + text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        return (lead.isEmpty ? "♪" : String(lead), String(inner))
    }
}

/// Fixed-size volume control. Intrinsic width so the capsule glass stays a pill.
private struct ToolbarVolumeSlider: View {
    @Binding var volume: Double

    private let trackWidth: CGFloat = 112

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: trackWidth, height: 4)
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: max(4, trackWidth * volume), height: 4)
                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .offset(x: min(max(0, trackWidth * volume - 5), trackWidth - 10))
            }
            .frame(width: trackWidth, height: 14)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        volume = min(max(0, g.location.x / trackWidth), 1)
                    }
            )
        }
        .padding(.horizontal, 8)
        .frame(width: 176, height: 22)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.1)
            case .decrement: volume = max(0, volume - 0.1)
            default: break
            }
        }
    }
}

#if os(iOS)
private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
private struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context: Context) -> SquareRoutePicker {
        SquareRoutePicker()
    }
    func updateNSView(_ nsView: SquareRoutePicker, context: Context) {}
}

/// AVRoutePickerView's intrinsic size is not square, so toolbar glass becomes
/// a squircle. Pin it to a 22pt box so the item can be a circle.
private final class SquareRoutePicker: NSView {
    private let picker = AVRoutePickerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.isRoutePickerButtonBordered = false
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentHuggingPriority(.required, for: .vertical)
        addSubview(picker)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func layout() {
        super.layout()
        picker.frame = bounds
    }
}
#endif

import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import AVFAudio
#else
import AppKit
#endif

/// Full Now Playing (UI spec §3.3). On macOS this *is* the window: traffic
/// lights stay, close / volume / AirPlay live in the real toolbar, and the
/// wash shows through a hidden title. On iPhone it is a swipe-to-dismiss
/// sheet that zooms from the mini player; on iPad a full-screen cover with
/// Music's grabber-plus-swipe dismissal (a sheet can no longer be trusted
/// full-screen — `.page` sizing presented as a floating card on iPadOS 27).
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(PartyStore.self) private var party
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthController.self) private var auth
    @Environment(ToastCenter.self) private var toast
    // Upstream restores the last expanded-player surface and starts on MAIN
    // for a fresh install. Persisting this here also keeps rotation/reopening
    // from unexpectedly dropping a listener into lyrics.
    @State private var pane: PlayerPane = PlayerPane.restored
    @State private var lyricsControlsOpen = true
    @State private var lyricsControlActivity = 0
    @State private var lyricsScrubbing = false
    @State private var volumeDragging = false
    @State private var showOutputDevice = false
    @State private var showPipeline = false
    @State private var showLyricsOffset = false
    @State private var showLyricsSources = false
    /// The offset, held here so a change re-renders the lyrics without the sheet
    /// being open. The notification is the signal; this is the value it carries.
    @State private var lyricsOffsetMs: Int32 = LyricsOffsetBridge.offsetMs()

    var body: some View {
        // The platform split has to close *inside* a `Group`: a `#if` in a view
        // builder is two statements, and the `.sheet` after it has nothing to
        // attach to. Both branches present the same readout.
        Group {
            #if os(macOS)
            macOSBody
            #else
            iOSBody
            #endif
        }
        .sheet(isPresented: $showPipeline) {
            AudioPipelineSheet()
        }
        .sheet(isPresented: $showOutputDevice) {
            OutputDeviceSheet()
                .environment(controller)
        }
        .sheet(isPresented: $showLyricsOffset) {
            LyricsOffsetSheet()
                .environment(controller)
        }
        .sheet(isPresented: $showLyricsSources) {
            LyricsSourcesSheet(onSearchAgain: { controller.refetchLyrics() })
        }
        // The offset is adjusted *against the track playing*, so the effect has to
        // be visible while the sheet is still open — a control that only took
        // hold on the next track could not be aimed at anything.
        .onReceive(NotificationCenter.default.publisher(for: .lyricsOffsetChanged)) { _ in
            lyricsOffsetMs = LyricsOffsetBridge.offsetMs()
        }
        .onChange(of: appModel.queueRevealRequested) { _, requested in
            if requested {
                withAnimation(.easeInOut(duration: 0.2)) { pane = .queue }
                appModel.queueRevealRequested = false
            }
        }
        .onChange(of: appModel.lyricsRevealRequested) { _, requested in
            if requested {
                withAnimation(.easeInOut(duration: 0.2)) { pane = .lyrics }
                appModel.lyricsRevealRequested = false
            }
        }
        .onChange(of: pane) { _, value in
            PlatformSettings.shared.putString(key: "last_player_screen", value: value.persistedValue)
            if value == .lyrics {
                lyricsControlsOpen = true
                lyricsControlActivity += 1
            }
        }
        .task(id: lyricsControlActivity) {
            while pane == .lyrics, lyricsControlsOpen {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard !Task.isCancelled, pane == .lyrics, lyricsControlsOpen else { return }
                if lyricsScrubbing { continue }
                withAnimation(.easeInOut(duration: 0.22)) { lyricsControlsOpen = false }
                return
            }
        }
    }

    // ---- macOS: window-root player -----------------------------------------
    #if os(macOS)
    private var macOSBody: some View {
        // The same arrangement decision iOS makes, and for the same reason: the
        // two shapes are one set of slots arranged differently, so a Mac window
        // that is not wide enough gets the portrait player rather than a
        // two-column layout whose columns cannot hold what they are given.
        GeometryReader { geo in
            ZStack {
                MeshBackdrop(seed: controller.current?.id.hashValue ?? 0, artwork: controller.current?.artworkData)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if usesBlurredArtworkBackdrop(width: geo.size.width, height: geo.size.height) {
                    FullArtworkBlurBackdrop(entry: controller.current)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if PlayerLayout.takesLandscapeShape(
                    width: geo.size.width, height: geo.size.height
                ) {
                    landscapePlayer(size: geo.size)
                } else {
                    portraitPlayer
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
            .keyboardShortcut(.cancelAction)
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

    #endif

    /// Upstream uses a cropped, pre-blurred cover behind lyrics and queue, and
    /// throughout landscape / tablet playback. The phone's main player keeps
    /// its seam-aware artwork mesh behind the edge-to-edge sleeve.
    private func usesBlurredArtworkBackdrop(width: CGFloat, height: CGFloat) -> Bool {
        pane != .main || PlayerLayout.takesLandscapeShape(width: width, height: height) ||
            width >= PlayerLayout.tabletMinWidth
    }

    private var isIPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var keepsLyricsPlaybackDeckVisible: Bool {
        #if os(iOS)
        isIPad
        #else
        true
        #endif
    }

    private var showsPlaybackStatusLine: Bool {
        #if os(iOS)
        !isIPad
        #else
        false
        #endif
    }

    // ---- The player's two shapes -------------------------------------------
    //
    // Upstream's portrait player is two things, and the port had them the wrong
    // way up. A *pinned bottom deck* — credits, scrubber, transport, toggles —
    // measured at its natural height and fixed to the foot of the screen, and the
    // space above it, which is whatever the artwork or an open panel needs.
    //
    // What this had instead was one `VStack`: the artwork at full size, then
    // everything else crammed beneath it, then lyrics and queue in a fixed
    // 220-point strip. That put the artwork's size in charge of the layout, left
    // the lyrics with a strip too short to read, and moved the transport
    // depending on what was on screen. Pinned to the foot instead, the deck is
    // in the same place on every screen, and all that is left above it is the
    // stage.
    //
    // Everything below this comment is shared by both platforms. Only the two
    // bodies and the two toolbars are platform-specific, and they are the
    // arrangement — which is the only thing that should differ.
    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            // The arrangement is the only thing that differs between the two
            // shapes, so the arrangement is the only thing decided here. Every
            // slot below — the sleeve, the panes, the deck — is built once and
            // used by both, which is upstream's arrangement and the reason
            // rotating mid-song carries the open pane, the scrub and the
            // translation mode across instead of resetting them.
            GeometryReader { geo in
                ZStack {
                    MeshBackdrop(seed: controller.current?.id.hashValue ?? 0, artwork: controller.current?.artworkData)
                        .ignoresSafeArea()
                    if !isIPad && pane == .main && !PlayerLayout.takesLandscapeShape(width: geo.size.width, height: geo.size.height) && fullBleedOn {
                        ArtworkContinuation(entry: controller.current, seam: geo.size.width)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    if usesBlurredArtworkBackdrop(width: geo.size.width, height: geo.size.height) {
                        FullArtworkBlurBackdrop(entry: controller.current)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }

                    if PlayerLayout.takesLandscapeShape(
                        width: geo.size.width, height: geo.size.height
                    ) {
                        landscapePlayer(size: geo.size)
                    } else {
                        portraitPlayer
                    }
                }
            }
            // Full-screen covers have no swipe-to-dismiss of their own, so the
            // iPad cover gets Music's treatment: a grabber pill top-center
            // plus a top-edge downward drag. The iPhone sheet keeps its
            // system drag indicator and needs no chrome here. The drag is
            // gated to starts in the top chrome band with a deliberate
            // downward travel, so queue/lyrics scrolling underneath never
            // trips it (child scroll gestures win ties by default anyway).
            .overlay(alignment: .top) {
                if isIPad {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 42, height: 5)
                        .padding(.top, 10)
                        .accessibilityLabel("Close")
                        .accessibilityAction { dismiss() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard isIPad,
                              value.translation.height > 140,
                              abs(value.translation.width) < 80,
                              value.startLocation.y < 120
                        else { return }
                        dismiss()
                    }
            )
            .toolbar(.hidden, for: .navigationBar)
            .toolbarTitleDisplayMode(.inline)
            // Keep the established edge-to-edge phone artwork. The iPad page
            // respects its system top inset so the player has room for chrome.
            .ignoresSafeArea(.container, edges: isIPad ? [] : .top)
        }
    }
    #endif

    /// The shape test lives in [PlayerLayout] with the rest of the window rules,
    /// so the thresholds have one definition and can be checked without a window.

    /// The portrait player: stage above, pinned deck below.
    private var portraitPlayer: some View {
        VStack(spacing: 0) {
            stage
            if pane != .lyrics || lyricsControlsOpen || keepsLyricsPlaybackDeckVisible {
                deck
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: lyricsControlsOpen)
    }

    /// The landscape player: two columns.
    /// On phones: compact two-column player.
    /// On iPad & macOS: Apple Music standard two-column player with permanent transport on the left
    /// and dedicated Lyrics / Up Next panel on the right.
    private func landscapePlayer(size: CGSize) -> some View {
        let compact = PlayerLayout.isCompactLandscape(width: size.width, height: size.height)
        let gutter = PlayerLayout.gutter(compact: compact)
        return Group {
            if compact {
                compactLandscapePlayer(size: size, gutter: gutter)
            } else {
                desktopLandscapePlayer(size: size, gutter: gutter)
            }
        }
    }

    private func compactLandscapePlayer(size: CGSize, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    artworkStage(
                        side: max(80, min(geo.size.width, geo.size.height)),
                        collapsed: false
                    )
                }
                playerActionRow
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, gutter)

            Group {
                switch pane {
                case .main:
                    VStack(spacing: 14) {
                        creditsRow
                        currentLyricStrip
                        positionControls
                        playerTransport
                    }
                    .transition(.opacity)
                case .lyrics, .queue:
                    panel(showsQueueCurrentTrackHeader: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: pane)
        }
        .frame(maxWidth: PlayerLayout.landscapeMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func desktopLandscapePlayer(size: CGSize, gutter: CGFloat) -> some View {
#if os(macOS)
        let maximumWidth = PlayerLayout.macLandscapeMaxWidth
        let artworkMaximum: CGFloat = 460
        let artworkHeightFraction: CGFloat = 0.46
        let leftColumnMaximum: CGFloat = 480
#else
        let maximumWidth = PlayerLayout.ipadLandscapeMaxWidth
        let artworkMaximum: CGFloat = 560
        let artworkHeightFraction: CGFloat = 0.58
        let leftColumnMaximum: CGFloat = 600
#endif
        return HStack(spacing: 36) {
            // Left column: Large Album Artwork + Full Transport Deck
            VStack(spacing: 16) {
                Spacer(minLength: 0)

                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    artworkStage(side: max(180, side), collapsed: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(maxHeight: min(size.height * artworkHeightFraction, artworkMaximum))

                VStack(spacing: 12) {
                    creditsRow

                    if showsPlaybackStatusLine, let status = songStatusLine {
                        Text(status)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .padding(.horizontal, 16)
                    }

                    positionControls
                        .padding(.horizontal, 12)

                    playerTransport

                    #if os(iOS)
                    if !controller.hideVolumeBar {
                        deckVolumeRow
                            .padding(.horizontal, 12)
                    }
                    #endif
                    // The pane-reactive pill lives on every platform: queue
                    // modes in the queue pane, output/party elsewhere. It used
                    // to sit inside the iOS gate below, so macOS never showed
                    // it at all.
                    actionRowPill
                    #if os(iOS)
                    Text(outputCaption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .accessibilityLabel(outputCaption)
                    #endif
                }
                .frame(maxWidth: leftColumnMaximum - 40)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: leftColumnMaximum)
            // No leading inset when the player stands alone: it centers in
            // the full width rather than sitting gutter-shifted.
            .padding(.leading, pane == .main ? 0 : gutter)

            // Right column: Lyrics or Queue — and nothing in the main pane.
            // With neither panel selected the player takes the full width,
            // centered; an empty panel column would just leave dead space.
            if pane != .main {
                Group {
                    if pane == .queue {
                        UpNextPane(
                            showsCurrentTrackHeader: false,
                            onOpenLyrics: { pane = .lyrics }
                        )
                            .transition(.opacity)
                    } else {
                        desktopLyricsPane
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
                .padding(.trailing, gutter)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: maximumWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if pane == .lyrics {
                lyricsToolsButton
                    .padding(.trailing, gutter)
                    .padding(.top, 18)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            landscapePaneSwitcher
                .padding(.trailing, gutter)
                .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: pane)
    }

    private var landscapePaneSwitcher: some View {
        // Two separate buttons with air between them, like Music: lyrics and
        // queue are mutually exclusive in function but not one joined
        // toggle — no shared capsule, no cramped spacing. Each one toggles:
        // tapping the highlighted pane returns to the main player, so the
        // switcher can always reach the neither-selected state.
        HStack(spacing: 18) {
            actionGlyph(.bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                Haptics.play(.expand)
                pane = pane == .lyrics ? .main : .lyrics
            }
            actionGlyph(.bchQueue, selected: pane == .queue, label: "Up Next") {
                Haptics.play(.expand)
                pane = pane == .queue ? .main : .queue
            }
        }
    }

    private var lyricsToolsButton: some View {
        Menu {
            Button("Change Lyrics Source", systemImage: "text.magnifyingglass") {
                showLyricsSources = true
            }
            Button("Adjust Lyrics Timing", systemImage: "slider.horizontal.2.square") {
                showLyricsOffset = true
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Lyrics options")
        .accessibilityLabel("Lyrics options")
    }

    private var desktopLyricsPane: some View {
        TimelineView(.animation) { timeline in
            LyricsPane(
                lines: controller.displayedLyrics,
                loading: controller.lyricsLoading,
                position: controller.livePosition(at: timeline.date),
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                alignmentInProgress: controller.lyricsAligning,
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: lyricsOffsetMs,
                sourceVisible: true,
                onChangeSource: { showLyricsSources = true },
                onRevealControls: {},
                onFocusLyrics: {}
            )
        }
    }

    /// Everything above the deck: the artwork, or whichever panel is open.
    ///
    /// Takes all the height the deck has left, so the artwork is as large as the
    /// window allows on a tall phone and the panels get the full column on a
    /// short one — which is the trade upstream makes, in the opposite direction
    /// from a fixed strip.
    private var stage: some View {
        GeometryReader { geo in
            let collapsed = pane != .main
            // The largest square that fits, with the gutters the player keeps.
            // Measured rather than assumed, so a short window shrinks the
            // artwork instead of pushing the deck off the bottom.
            let full = PlayerLayout.portraitArtworkSide(
                stageWidth: geo.size.width,
                stageHeight: geo.size.height,
                maximumSide: isIPad
                    ? min(
                        PlayerLayout.ipadPortraitArtworkMaxSide,
                        geo.size.width * PlayerLayout.ipadPortraitArtworkWidthFraction
                    )
                    : nil
            )
            // Full Bleed remains a phone preference; the iPad keeps its
            // contained sleeve even when the preference is enabled.
            let hero = !isIPad && !collapsed && PlayerLayout.usesFullBleedArtwork(
                width: geo.size.width, preferenceEnabled: fullBleedOn
            )
            // On iPad portrait, the panel takes the whole stage above the
            // pinned transport; it is part of the player page, not a nested sheet.
            VStack(spacing: 0) {
                if pane == .lyrics {
                    lyricsHeader
                } else if pane == .main {
                    if isIPad {
                        artworkStage(side: full, collapsed: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        artworkStage(
                            side: hero ? geo.size.width : full,
                            collapsed: false,
                            hero: hero
                        )
                    }
                }
                if collapsed {
                    panel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if pane == .lyrics {
                    lyricsToolsButton
                        .padding(.trailing, 20)
                        .padding(.bottom, 12)
                }
            }
            .animation(.snappy(duration: 0.28), value: pane)
            // Additive sleeve swipe, upstream's vertical drag: up past 60pt
            // opens Up Next, down while a panel is up returns to the player.
            // The pane buttons stay the primary control; this never replaces
            // them. A plain `gesture` so an open panel's own scroll wins the
            // touch first.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = value.translation.width
                        // Clearly vertical before it counts.
                        guard abs(dy) > abs(dx) else { return }
                        if dy < -60 && pane == .main {
                            Haptics.play(.expand)
                            pane = .queue
                        } else if dy > 60 && pane != .main {
                            Haptics.play(.tap)
                            pane = .main
                        }
                    }
            )
            .accessibilityHint("Swipe up for Up Next, swipe down to return to the player.")
        }
    }

    /// The artwork sleeve.
    ///
    /// A button exactly when there is somewhere to go back to, which is the whole
    /// point of the collapse: upstream shrinks the artwork into a header when a
    /// panel is up, and the shrunk artwork is the way back to the player. In the
    /// main pane it is not a button, because a big artwork that does nothing when
    /// tapped is a control that lies about being one.
    ///
    /// The card is [SleeveArt] — still art with the canvas over it and the
    /// paused shrink inside a fixed slot — unless full-bleed is on and the
    /// window is one the setting acts on, in which case it is the [HeroArtwork]
    /// banner, edge to edge with its bottom dissolved into the mesh.
    @ViewBuilder
    private func artworkStage(side: CGFloat, collapsed: Bool, hero: Bool = false) -> some View {
        if collapsed {
            Button {
                Haptics.play(.tap)
                pane = .main
            } label: {
                SleeveArt(
                    entry: controller.current,
                    canvasURL: controller.canvasURL,
                    fallbackURL: controller.canvasFallbackURL,
                    isPlaying: controller.isPlaying,
                    side: side
                )
                .id(controller.current?.id)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to player")
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else if hero {
            HeroArtwork(
                entry: controller.current,
                canvasURL: controller.canvasURL,
                fallbackURL: controller.canvasFallbackURL,
                isPlaying: controller.isPlaying
            )
            .id(controller.current?.id)
            // Hero size is the actual viewport width, independent of the
            // remaining height above the controls.
            .frame(width: side, height: side)
            .overlay(alignment: .top) {
                if let caption = playbackOriginCaption {
                    Text(caption)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                        .padding(.top, 22)
                }
            }
            .accessibilityLabel(controller.current?.title ?? "Nothing playing")
        } else {
            SleeveArt(
                entry: controller.current,
                canvasURL: controller.canvasURL,
                fallbackURL: controller.canvasFallbackURL,
                isPlaying: controller.isPlaying,
                side: side
            )
            .id(controller.current?.id)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .accessibilityLabel(controller.current?.title ?? "Nothing playing")
        }
    }

    /// The selected content pane, filling the portrait stage or the requested
    /// portion of a compact landscape layout.
    @ViewBuilder
    private func panel(showsQueueCurrentTrackHeader: Bool = true) -> some View {
        switch pane {
        case .main:
            Color.clear
        case .lyrics:
            // Frame-driven, not poll-driven. `controller.position` only moves
            // when the transport tick reads the engine — four times a second —
            // so a word highlight judged against it can only change on those
            // four ticks, and steps in 250 ms jumps. Upstream drives the pane
            // from a frame clock for exactly this reason. The interpolated
            // position is still the engine's measurement; the TimelineView only
            // decides how often we ask where it has got to.
            TimelineView(.animation) { timeline in
            LyricsPane(
                lines: controller.displayedLyrics,
                loading: controller.lyricsLoading,
                position: controller.livePosition(at: timeline.date),
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                alignmentInProgress: controller.lyricsAligning,
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: lyricsOffsetMs,
                sourceVisible: lyricsControlsOpen,
                onChangeSource: { showLyricsSources = true },
                onRevealControls: { revealLyricsControls() },
                onFocusLyrics: { hideLyricsControls() }
            )
            }
        case .queue:
            UpNextPane(
                showsCurrentTrackHeader: showsQueueCurrentTrackHeader,
                onOpenLyrics: { pane = .lyrics }
            )
        }
    }

    /// The pinned playback deck: credits, scrubber, transport, volume and actions.
    ///
    /// Measured at its natural height and fixed to the foot, so opening the
    /// lyrics does not shove the transport down. The pane toggles live here
    /// rather than floating over the artwork: they are *which pane* is showing,
    /// which is the same question the rest of this block answers.
    private var deck: some View {
        VStack(spacing: 14) {
            // Credits, status and strip live on the main player only. Upstream's
            // queue screen goes Lyrics link straight to the scrubber — the song
            // title and the sung line sitting over the queue is this codebase's
            // invention, and it is what buried the list.
            if pane == .main { creditsRow }
            // The playback-origin caption / nerd line, hidden behind
            // `hide_song_status` exactly as upstream hides it.
            if pane == .main, showsPlaybackStatusLine, let status = songStatusLine {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(.horizontal, 24)
                    .accessibilityLabel(status)
            }
            // Phones keep the lyric strip in the main and queue panes. On iPad
            // the larger lyric/queue pane already has that space, so the pinned
            // deck stays focused on seek and playback controls.
            if pane != .lyrics && !isIPad { currentLyricStrip }
            positionControls
                .padding(.horizontal, 32)
            playerTransport
            // The volume capsule between transport and toggles, flanked by
            // speaker icons in the hairline style of `ThinSlider`. Gone when
            // `hide_volume_bar` is on, the same as upstream.
            if !controller.hideVolumeBar {
                deckVolumeRow
                    .padding(.horizontal, 32)
            }
            playerActionRow
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            // A scrim rather than a blur: the backdrop is already a mesh, and a
            // material over it muddies the colours the artwork set up. Short
            // enough to read as the foot of the screen rather than a sheet.
            LinearGradient(
                colors: [.clear, .black.opacity(0.30), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    /// Compact credits row that stays at the head of the lyrics surface while
    /// the playback deck can independently slide away for focused reading.
    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.play(.tap)
                pane = .main
            } label: {
                SleeveArt(
                    entry: controller.current,
                    canvasURL: controller.canvasURL,
                    fallbackURL: controller.canvasFallbackURL,
                    isPlaying: controller.isPlaying,
                    side: PlayerLayout.sleeveCollapsedSide
                )
                .id(controller.current?.id)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to player")

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.current?.title ?? "Nothing playing")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(controller.current?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if auth.signedIn, controller.current?.videoId != nil {
                GlassCircleButton(
                    icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                    label: controller.isLiked ? "Remove Like" : "Like"
                ) { controller.toggleLike() }
            }
            moreMenu
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    /// One line of the lyric being sung now — or why there is not one.
    ///
    /// A button, because tapping it opens the lyrics. That is the whole
    /// interaction: the strip is a preview of a pane rather than a display of its
    /// own, and a line of text that looks like the lyrics but cannot be reached
    /// by tapping it is the one part of the player a listener would try and fail.
    private var currentLyricStrip: some View {
        Button {
            Haptics.play(.expand)
            pane = pane == .lyrics ? .main : .lyrics
        } label: {
            Group {
                if let line = currentLyric {
                    Text(line)
                        .foregroundStyle(.white.opacity(0.92))
                } else if controller.lyricsLoading {
                    Text("Looking for lyrics…")
                        .foregroundStyle(.white.opacity(0.5))
                } else if controller.lyricsUnavailable {
                    Text("No lyrics for this track")
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    // Nothing has been looked for yet — a track whose lyrics are
                    // off, or a player with nothing loaded. Saying so is better
                    // than an empty gap where the words would be.
                    Text(controller.current == nil ? "" : "Lyrics off")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
            .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
            .padding(.horizontal, 24)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(currentLyric == nil)
        .accessibilityLabel(
            currentLyric.map { "Now singing: \($0)" }
                ?? (controller.lyricsLoading ? "Looking for lyrics" : "No lyrics")
        )
        .accessibilityHint("Opens the lyrics")
    }

    /// The line at the playhead, from the same set the lyrics pane shows and on
    /// the same adjusted clock — the offset applies to both, since they are
    /// showing the same thing in two sizes.
    private var currentLyric: String? {
        let lines = controller.displayedLyrics
        guard !lines.isEmpty else { return nil }
        let ms = max(0, Int64(controller.position * 1000) - Int64(lyricsOffsetMs))
        guard let index = lines.lastIndex(where: { $0.timeMs <= ms }) else { return nil }
        return lines[index].text
    }

    /// Title and artist, with the like and the overflow menu beside them.
    private var creditsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.current?.title ?? "Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                Text(creditLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            }
            Spacer(minLength: 8)
            if auth.signedIn, controller.current?.videoId != nil {
                GlassCircleButton(
                    icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                    label: controller.isLiked ? "Remove Like" : "Like"
                ) {
                    controller.toggleLike()
                }
                .help(controller.isLiked ? "Remove from Liked Music" : "Like")
            }
            moreMenu
        }
        .padding(.horizontal, 24)
    }

    /// Below-volume pill, pane-reactive on every layout that carries one:
    /// the queue-modes pill (shuffle · repeat · AutoPlay · AutoMix) in the
    /// queue pane, output/party everywhere else. One definition so the
    /// portrait deck, compact landscape and desktop columns cannot disagree
    /// about which pill a pane shows — the desktop column used to hardcode
    /// the output pill, which is why pane toggles never changed anything on
    /// iPad landscape or macOS.
    private var actionRowPill: some View {
        Group {
            if pane == .queue {
                queueModesPill
            } else {
                outputPartyPill
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// Which of the three panes is showing.
    ///
    /// The artwork toggle is here rather than implied by the artwork's size: a
    /// control that only exists while a panel is closed cannot be used to open
    /// the first one, and one that only exists while a panel is open cannot be
    /// used to leave it.
    /// Lyrics and Up Next stay at the two ends. The middle pill follows the
    /// pane through `actionRowPill`, the same definition every layout uses.
    private var playerActionRow: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let edgeInset = max(0, (geometry.size.width - (44 * 2 + 158)) / 4)
                HStack {
                    actionGlyph(.bchLyrics, selected: pane == .lyrics, label: "Lyrics") {
                        Haptics.play(.expand)
                        pane = pane == .lyrics ? .main : .lyrics
                    }
                    Spacer(minLength: 0)
                    // The queue pane swaps the output/party pill for the
                    // queue-modes pill (shuffle · repeat · AutoPlay · AutoMix).
                    // This is the pill's only home, and it is per platform and
                    // pane alike: iPad used to be excluded here, which is why its
                    // queue pane showed output controls instead of these.
                    actionRowPill
                    Spacer(minLength: 0)
                    actionGlyph(.bchQueue, selected: pane == .queue, label: "Up Next") {
                        Haptics.play(.expand)
                        pane = pane == .queue ? .main : .queue
                    }
                }
                .padding(.horizontal, edgeInset)
            }
            .frame(height: 44)

            if !outputCaption.isEmpty {
                Text(outputCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .accessibilityLabel(outputCaption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionGlyph(
        _ image: ImageResource,
        selected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                .frame(width: 44, height: 44)
                .background(.white.opacity(selected ? 0.2 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var outputPartyPill: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.play(.tap)
                showOutputDevice = true
            } label: {
                Image(systemName: "headphones")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 64, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio output")

            pillDivider

            Button {
                Haptics.play(.tap)
                if party.inParty {
                    appModel.partyMembersPresented = true
                } else {
                    appModel.listenTogetherPresented = true
                }
            } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(party.inParty ? 1 : 0.75))
                    .frame(width: 64, height: 44)
                    .background(.white.opacity(party.inParty ? 0.14 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(party.inParty ? "People listening" : "Listen Together")
        }
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    /// The phone queue keeps its established shuffle/repeat/AutoPlay pill.
    /// iPad and desktop show these modes with the queue itself instead.
    private var queueModesPill: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.play(controller.shuffleEnabled ? .toggleOff : .toggleOn)
                controller.toggleShuffle()
            } label: {
                Image(.bchShuffle)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.shuffleEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.shuffleEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.shuffleEnabled ? "Shuffle on" : "Shuffle off")

            pillDivider

            Button {
                Haptics.play(.select)
                controller.cycleRepeat()
            } label: {
                Group {
                    if controller.repeatMode == .one {
                        Text("1").font(.system(size: 19, weight: .bold))
                    } else {
                        Image(.bchRepeat).resizable().scaledToFit().frame(width: 22, height: 22)
                    }
                }
                .foregroundStyle(.white.opacity(controller.repeatMode == .off ? 0.75 : 1))
                .frame(width: 52, height: 44)
                .background(.white.opacity(controller.repeatMode == .off ? 0 : 0.14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(repeatLabel)

            pillDivider

            Button {
                Haptics.play(controller.autoplayEnabled ? .toggleOff : .toggleOn)
                controller.toggleAutoplay()
            } label: {
                Image(.bchInfinity)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.autoplayEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.autoplayEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.autoplayEnabled ? "AutoPlay on" : "AutoPlay off")

            pillDivider

            // AutoMix is the fourth and last slot, at the right end of the pill.
            // Deliberately a waveform rather than another infinity: AutoPlay and
            // AutoMix are separate switches and must not read as the same one.
            Button {
                Haptics.play(controller.automixEnabled ? .toggleOff : .toggleOn)
                controller.toggleAutomix()
            } label: {
                Image(systemName: "waveform")
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(controller.automixEnabled ? 1 : 0.75))
                    .frame(width: 52, height: 44)
                    .background(.white.opacity(controller.automixEnabled ? 0.14 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.automixEnabled ? "AutoMix on" : "AutoMix off")
            .help(controller.automixEnabled
                ? "AutoMix blends the end of one track into the next"
                : "AutoMix off — tracks change at the end")
        }
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private var pillDivider: some View {
        Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 44)
    }

    private var outputCaption: String {
        // The live CoreAudio route, which is the only place the *current*
        // output is named on iOS: cpal's default device does not follow a
        // route change, so plugging in AirPods would have kept reporting the
        // built-in speaker. Read it per render — the player re-renders on every
        // position tick, so a route change lands without any observer.
        #if os(iOS)
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
        let routeName = port.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        let routeName = controller.outputDevice.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        let lowered = routeName.lowercased()
        if controller.outputDevice.started, !routeName.isEmpty,
           !lowered.contains("default output") {
            return routeName
        }
        if party.inParty { return party.state.you?.name ?? "Playing together" }
        return "Default Device"
    }

    private func revealLyricsControls() {
        lyricsControlsOpen = true
        lyricsControlActivity += 1
    }

    private func hideLyricsControls() {
        lyricsControlsOpen = false
    }

    // iOS only — macOS has its own window-toolbar close button, in
    // `macPlayerToolbar`.
    #if os(iOS)
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

    /// Artist and album on one line, whichever of the two there is.
    ///
    /// One line rather than two because the deck has room for one: a title on
    /// two lines already, and a second line under it pushes the scrubber down and
    /// the deck is supposed to be the same height whatever is playing.
    private var creditLine: String {
        let artist = controller.current?.artist ?? ""
        let album = controller.current?.albumName ?? ""
        if artist.isEmpty { return album }
        if album.isEmpty { return artist }
        return "\(artist) — \(album)"
    }

    /// Upstream `AppSettings.fullBleedArtwork`: the portrait sleeve runs as a
    /// full-bleed banner rather than a card.
    private var fullBleedOn: Bool {
        PlatformSettings.shared.getBoolean(key: "full_bleed_artwork", default: true)
    }

    /// Upstream `AppSettings.hideSongStatus`: hides the playback-origin
    /// caption / nerd line under the credits.
    private var hideSongStatus: Bool {
        PlatformSettings.shared.getBoolean(key: "hide_song_status", default: false)
    }

    /// Upstream `AppSettings.legacyMeshGradient`: the backdrop renders a single
    /// static wash instead of animated blobs.
    private var legacyMesh: Bool {
        PlatformSettings.shared.getBoolean(key: "legacy_mesh_gradient", default: false)
    }

    /// The playback-origin caption under the credits: upstream's
    /// `playbackOriginText` ("Playing from …"), falling back to the nerd line
    /// while a lossless lookup is still racing. Nil when hidden or unknown.
    private var songStatusLine: String? {
        guard !hideSongStatus else { return nil }
        if let nerd = controller.nerd {
            let line = nerdLine(nerd)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
        }
        guard let current = controller.current else { return nil }
        if current.isLocal { return "Playing from Local files" }
        if current.source.hasPrefix("yt:") { return "Playing from YouTube" }
        if !current.source.isEmpty { return "Playing from \(current.source)" }
        return nil
    }

    /// The compact source caption that sits over upstream's full-bleed cover.
    /// Nerd statistics stay in the deck; they are not the origin of playback.
    private var playbackOriginCaption: String? {
        guard !hideSongStatus, let current = controller.current else { return nil }
        if let context = controller.playbackContext, !context.isEmpty {
            return "Playing from \(context)"
        }
        if current.isLocal { return "Playing from Local files" }
        if current.source.hasPrefix("yt:") { return "Playing from YouTube" }
        guard !current.source.isEmpty else { return nil }
        return "Playing from \(current.source)"
    }

    // ---- Shared pieces ------------------------------------------------------

    private var positionControls: some View {
        VStack(spacing: 6) {
            ThinSlider(
                value: controller.position,
                maximum: controller.duration,
                mixing: controller.smartMixInProgress,
                transitionWindow: controller.smartTransitionWindow.flatMap { w in
                    w.end > w.start ? w.start...w.end : nil
                },
                onEditingChanged: { controller.seek(to: $0) },
                onDraggingChanged: { dragging in
                    lyricsScrubbing = dragging
                    if !dragging { lyricsControlActivity += 1 }
                }
            )
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

    /// The iOS volume row: upstream `VolumeRow` in the hairline capsule style
    /// of `ThinSlider`, bound to the controller's volume with the system
    /// speaker icons either side. The hardware buttons route through the same
    /// system volume this writes, so the two never disagree.
    private var deckVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let x = w * min(max(controller.volume, 0), 1)
                ZStack(alignment: .leading) {
                    let trackHeight: CGFloat = volumeDragging ? 10 : 6
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(.white.opacity(0.75))
                        .frame(width: max(trackHeight, x), height: trackHeight)
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(0, x - 5), w - 10))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            volumeDragging = true
                            controller.volume = min(max(0, g.location.x / w), 1)
                        }
                        .onEnded { _ in volumeDragging = false }
                )
            }
            .frame(height: 14)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(controller.volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.volume = min(1, controller.volume + 0.1)
            case .decrement: controller.volume = max(0, controller.volume - 0.1)
            default: break
            }
        }
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
    /// Transport: skip, play, skip — and nothing else.
    ///
    /// Shuffle and repeat are not here. They live in the queue-modes pill
    /// (`queueModesPill`), which is their single home on every platform and
    /// pane; repeating them beside the playback keys put the same two switches
    /// on screen twice with nothing saying they are the same switch.
    private var playerTransport: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.play(.skipPrevious)
                controller.previous()
            } label: {
                Image(.bchPrevious)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 53, height: 53)
                    .scaleEffect(y: 0.85)
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
                    if controller.isBuffering {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                            .frame(width: 38, height: 38)
                    } else {
                        Image(controller.isPlaying ? .bchTransportPause : .bchTransportPlay)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 74, height: 74)
                            .playerGlyph()
                    }
                }
                .frame(width: 92, height: 92)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.current == nil && !controller.isBuffering)
            .help(controller.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(controller.isBuffering ? "Buffering" : (controller.isPlaying ? "Pause" : "Play"))

            Button {
                Haptics.play(.skipNext)
                controller.next()
            } label: {
                Image(.bchNext)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 53, height: 53)
                    .scaleEffect(y: 0.85)
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayNext)
            .help("Next")
            .accessibilityLabel("Next track")
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
            }
            // The output route and live pipeline have their own player control;
            // this menu follows the upstream track-action list.
            if !controller.displayedLyrics.isEmpty {
                Divider()
                Button("Lyrics Offset…") { showLyricsOffset = true }
            }
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
        if let gain = nerd.loudnessGainDb, gain != 0 {
            parts.append(String(format: "%+.1f dB", gain))
        }
        if let tier = controller.analysisTier, !tier.isEmpty { parts.append(tier) }
        if let sources = controller.analysisSources, !sources.isEmpty { parts.append(sources) }
        if let conf = controller.analysisConfidence { parts.append(String(format: "%.0f%% mix", conf * 100)) }
        if controller.smartMixInProgress { parts.append("Automix") }
        // Only when the transition actually cued the track somewhere other than
        // the top — which is now the minority of transitions, so a non-nil value
        // is the interesting one.
        if let cue = controller.automixCueSeconds, cue > 0.05 {
            parts.append(String(format: "in at %@", QueueEntry.formatDuration(cue)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Which of the three the portrait player is showing.
///
/// Three states, not two, and the third is the important one. Upstream's player
/// has a *main* pane that the artwork fills, and lyrics and queue that replace
/// it; a two-state enum can only ever hold one of the last two at a time and has
/// nowhere to go back to, which is why the artwork has to be a control to close
/// them.
private enum PlayerPane {
    case main, lyrics, queue

    static var restored: PlayerPane {
        switch PlatformSettings.shared.getString(key: "last_player_screen", default: "MAIN") {
        case "LYRICS": .lyrics
        case "QUEUE": .queue
        default: .main
        }
    }

    var persistedValue: String {
        switch self {
        case .main: "MAIN"
        case .lyrics: "LYRICS"
        case .queue: "QUEUE"
        }
    }
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

/// Queue column. The current song stays in the compact player header when
/// there is no neighbouring player column (portrait); wide layouts already have
/// that information beside the queue, so they omit the duplicate header.
private struct UpNextPane: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth

    var showsCurrentTrackHeader = true
    var onOpenLyrics: () -> Void = {}
    @State private var hasScrolledOnce = false

    /// The queue list, one layout on every platform: "Queue" with Clear, a
    /// "Now playing" section for the current track, "Up next" with drag
    /// handles left and remove buttons right, the AutoPlay section, and a
    /// Lyrics link at the foot. iPad and mac used to render a separate
    /// "Continue Playing" list (no sections, swipe-only delete); the two
    /// layouts disagreed about what a queue is, so there is one now.
    @ViewBuilder
    var body: some View {
        queueList
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The big current-track header (artwork, like, menu) only where
            // the artwork column is absent. iPad landscape and mac show all
            // of that on the left already; repeating it here doubles the
            // song, the like and the menu.
            if showsCurrentTrackHeader {
                queueHeader
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Queue")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if !manualUpcoming.isEmpty || !autoplayUpcoming.isEmpty {
                    Button("Clear") { controller.clearUpcoming() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 24)
            .id("queueTop")

            if controller.current == nil && manualUpcoming.isEmpty && autoplayUpcoming.isEmpty {
                Text("Nothing playing.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        if controller.current != nil {
                            Text("Now playing")
                                .font(.headline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, 12)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 6, trailing: 24))
                            currentQueueRow
                        }
                        if !manualUpcoming.isEmpty {
                            Text("Up next")
                                .font(.headline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, 16)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 6, trailing: 24))
                            ForEach(Array(manualUpcoming.enumerated()), id: \.element.id) { localIndex, item in
                                queueListRow(item, section: 0, index: localIndex, rows: manualUpcoming)
                            }
                            .onMove { source, dest in move(source, dest, rows: manualUpcoming) }
                            .onDelete { offsets in remove(offsets, rows: manualUpcoming) }
                        }
                        if controller.autoplayEnabled || !autoplayUpcoming.isEmpty {
                            HStack(spacing: 8) {
                                Image(.bchInfinity)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(.white.opacity(0.75))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("AutoPlay")
                                        .font(.headline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text(autoplayUpcoming.isEmpty
                                         ? "Similar music will keep playing"
                                         : "Similar music, selected to play next")
                                        .font(.callout)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            .padding(.vertical, 14)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                            if !autoplayUpcoming.isEmpty {
                                ForEach(Array(autoplayUpcoming.enumerated()), id: \.element.id) { localIndex, item in
                                    queueListRow(item, section: 1, index: localIndex, rows: autoplayUpcoming)
                                }
                                .onMove { source, dest in move(source, dest, rows: autoplayUpcoming) }
                                .onDelete { offsets in remove(offsets, rows: autoplayUpcoming) }
                            }
                        }
                        Button {
                            Haptics.play(.expand)
                            onOpenLyrics()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.body.weight(.medium))
                                Text("Lyrics")
                                    .font(.headline.weight(.medium))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.04),
                                .init(color: .black, location: 0.96),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .animation(.easeOut(duration: 0.2), value: queueSignature)
                    .onChange(of: controller.playingIndex) { _, _ in
                        if hasScrolledOnce {
                            withAnimation { proxy.scrollTo("queueTop", anchor: .top) }
                        } else {
                            proxy.scrollTo("queueTop", anchor: .top)
                            hasScrolledOnce = true
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var currentQueueRow: some View {
        Button {
            let at = controller.playingIndex
            if controller.queue.indices.contains(at) {
                controller.playQueueItem(at: at)
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(entry: controller.current, side: 40)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.current?.title ?? "")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(controller.current?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Now playing")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func queueListRow(_ item: QueueRow, section: Int, index: Int, rows: [QueueRow]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 20, height: 44)
                .contentShape(.rect)
                .onDrag { NSItemProvider(object: "\(section):\(index)" as NSString) }
            Button {
                controller.playQueueItem(at: item.index)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(entry: item.entry, side: 44)
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
            Button {
                controller.removeFromQueue(at: item.index)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.entry.title) from queue")
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 20))
        .onDrop(of: [.text], delegate: QueueReorderDelegate(section: section, rows: rows, destIndex: index) { from, dest in
            move(IndexSet(integer: from), dest, rows: rows)
        })
    }

    private var autoplayStart: Int { controller.autoplaySectionStart }

    /// Upcoming manual rows — never includes AutoPlay, never the playing track.
    private var manualUpcoming: [QueueRow] {
        rows(in: controller.firstMovableQueueIndex..<autoplayStart)
    }

    private var autoplayUpcoming: [QueueRow] {
        rows(in: autoplayStart..<controller.queue.count)
    }

    private func rows(in range: Range<Int>) -> [QueueRow] {
        guard range.lowerBound < range.upperBound else { return [] }
        return range.compactMap { index in
            guard controller.queue.indices.contains(index) else { return nil }
            return QueueRow(index: index, entry: controller.queue[index])
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(entry: controller.current, side: 56)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.current?.title ?? "Nothing playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(controller.current?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if auth.signedIn, controller.current?.videoId != nil {
                GlassCircleButton(
                    icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                    label: controller.isLiked ? "Remove Like" : "Like"
                ) { controller.toggleLike() }
            }
            Menu {
                if let current = controller.current {
                    SongActionButtons(entry: current, showSleepTimer: true, showDebugLog: true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .help("More")
        }
        .padding(.horizontal, 24)
    }

    /// What the row-motion animation tracks: every move changes it, nothing
    /// else does.
    private var queueSignature: String {
        (manualUpcoming.map(\.id) + autoplayUpcoming.map(\.id)).joined(separator: "|")
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
}

/// Reorders within one queue section from the row's drag handle, like
/// upstream: a drag never leaves its section, and neighbours trade slots
/// live as the held row crosses them. The payload carries its section tag so
/// a drop onto the other section's rows is ignored, not misfiled.
private struct QueueReorderDelegate: DropDelegate {
    let section: Int
    let rows: [QueueRow]
    let destIndex: Int
    let onMove: (Int, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let parts = text.split(separator: ":").map(String.init).compactMap(Int.init)
            guard parts.count == 2, parts[0] == section else { return }
            let from = parts[1]
            guard rows.indices.contains(from), rows.indices.contains(destIndex), from != destIndex else { return }
            Task { @MainActor in onMove(from, destIndex) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
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

/// Upstream ArtworkMeshBackdrop: preserve the cover's bottom row above the
/// seam, then stretch its inverted, horizontally shifted colour grid below it.
private struct ArtworkContinuation: View {
    var entry: QueueEntry?
    var seam: CGFloat
    @State private var texture: CGImage?

    var body: some View {
        GeometryReader { geo in
            if let texture, let edge = texture.cropping(to: CGRect(x: 0, y: 0, width: texture.width, height: 1)) {
                VStack(spacing: 0) {
                    Image(decorative: edge, scale: 1).resizable()
                        .frame(height: min(seam, geo.size.height))
                    Image(decorative: texture, scale: 1).resizable()
                        .frame(height: max(0, geo.size.height - seam))
                }
                .frame(width: geo.size.width)
            }
        }
        .allowsHitTesting(false)
        .task(id: entry?.thumbnailUrl ?? entry?.id) {
            guard let entry else { return }
            let source: PlatformImage?
            if let data = entry.artworkData {
                source = PlatformImage(data: data)
            } else if let url = entry.thumbnailUrl {
                source = await ArtworkCache.shared.load(SharedArtwork.sized(url, 120) ?? url)
            } else { source = nil }
            guard let source else { return }
            let key = entry.id
            let result = await Task.detached(priority: .utility) {
                Self.makeTexture(source, key: key)
            }.value
            guard !Task.isCancelled else { return }
            texture = result
        }
    }

    nonisolated private static func makeTexture(_ image: PlatformImage, key: String) -> CGImage? {
        #if os(iOS)
        guard let image = image.cgImage else { return nil }
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        guard let image = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        #endif
        let n = 120, gridSize = 6, size = 32
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: n, height: n,
                bitsPerComponent: 8, bytesPerRow: n * 4, space: colorSpace, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var grid = [[Double]](repeating: [0, 0, 0], count: 36)
        for y in 0..<n {
            for x in 0..<n {
                let cell = ((n - 1 - y) / 20) * gridSize + x / 20
                for c in 0..<3 { grid[cell][c] += Double(pixels[(y * n + x) * 4 + c]) / 400 }
            }
        }
        // Upstream's small HSL saturation lift and near-black lightness floor.
        for i in grid.indices {
            let rgb = grid[i].map { $0 / 255 }
            let hi = rgb.max()!, lo = rgb.min()!
            let light = (hi + lo) / 2, chroma = hi - lo
            let liftedLight = max(0.045, light)
            let saturation = chroma > 0 ? chroma / max(0.000001, 1 - abs(2 * light - 1)) : 0
            let liftedChroma = (1 - abs(2 * liftedLight - 1)) * min(1, saturation * 1.12)
            grid[i] = rgb.map { value in
                let lifted = liftedLight + (chroma > 0 ? (value - light) * liftedChroma / chroma : 0)
                return min(255, max(0, lifted * 255))
            }
        }
        // Stable per cover; keep neighbouring cells together and the seam intact.
        let seed = key.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        let shift = Int(seed % 6), mirror = seed & 1 == 1
        var rotated = grid
        for y in 1..<gridSize {
            for x in 0..<gridSize {
                rotated[y * gridSize + x] = grid[y * gridSize + ((mirror ? 5 - x : x) + shift) % gridSize]
            }
        }
        func smooth(_ v: Double) -> Double {
            let t = min(1, max(0, v)); return t * t * (3 - 2 * t)
        }
        var out = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let fy = (Double(y) + 0.5) / Double(size) * 6 - 0.5
            let y0 = min(5, max(0, Int(floor(fy)))), y1 = min(5, y0 + 1)
            let wy = smooth(fy - Double(y0))
            for x in 0..<size {
                let fx = (Double(x) + 0.5) / Double(size) * 6 - 0.5
                let x0 = min(5, max(0, Int(floor(fx)))), x1 = min(5, x0 + 1)
                let wx = smooth(fx - Double(x0))
                for c in 0..<3 {
                    let top = rotated[y0 * 6 + x0][c] * (1 - wx) + rotated[y0 * 6 + x1][c] * wx
                    let bottom = rotated[y1 * 6 + x0][c] * (1 - wx) + rotated[y1 * 6 + x1][c] * wx
                    out[(y * size + x) * 4 + c] = UInt8(clamping: Int((top * (1 - wy) + bottom * wy).rounded()))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Upstream's `FullArtworkBlurBackdrop` for lyrics, queue, landscape and iPad:
/// a cropped copy of the cover blurred once at thumbnail resolution, then
/// scaled across the screen under a dark readability wash.
private struct FullArtworkBlurBackdrop: View {
    let entry: QueueEntry?
    @State private var image: PlatformImage?

    private var cacheKey: String? {
        guard let entry else { return nil }
        return entry.thumbnailUrl ?? "embedded:\(entry.id)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    #endif
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.34), location: 0),
                            .init(color: .black.opacity(0.48), location: 0.55),
                            .init(color: .black.opacity(0.64), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .opacity(image == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.32), value: image != nil)
        }
        .task(id: cacheKey) {
            guard let entry, let cacheKey else {
                image = nil
                return
            }
            let prepared = await PlayerArtworkBlurCache.image(
                key: cacheKey,
                url: entry.thumbnailUrl,
                data: entry.artworkData
            )
            guard !Task.isCancelled else { return }
            image = prepared
        }
        .accessibilityHidden(true)
    }
}

/// Small, pre-blurred cover copies are cached just like upstream's 128px
/// bitmap. The expensive Core Image work runs away from the main thread.
private enum PlayerArtworkBlurCache {
    private static let images = NSCache<NSString, PlatformImage>()
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let pixelLimit: CGFloat = 256

    static func image(key: String, url: String?, data: Data?) async -> PlatformImage? {
        if let cached = images.object(forKey: key as NSString) { return cached }
        let source: PlatformImage?
        if let data {
            source = PlatformImage(data: data)
        } else if let url {
            source = await ArtworkCache.shared.load(SharedArtwork.sized(url, 256) ?? url)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let prepared = await Task.detached(priority: .utility) {
            renderBlurred(source)
        }.value
        if let prepared { images.setObject(prepared, forKey: key as NSString) }
        return prepared
    }

    private static func renderBlurred(_ source: PlatformImage) -> PlatformImage? {
        #if os(iOS)
        guard let cgImage = source.cgImage else { return nil }
        #else
        var proposed = CGRect(origin: .zero, size: source.size)
        guard let cgImage = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        #endif

        let input = CIImage(cgImage: cgImage)
        let sourceExtent = input.extent
        let scale = min(1, pixelLimit / max(sourceExtent.width, sourceExtent.height))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = scaled.clampedToExtent()
        filter.radius = 22
        guard let output = filter.outputImage?.cropped(to: scaled.extent),
              let blurred = context.createCGImage(output, from: scaled.extent)
        else { return nil }
        #if os(iOS)
        return UIImage(cgImage: blurred)
        #else
        return NSImage(cgImage: blurred, size: .zero)
        #endif
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
        Group {
            if legacyMesh {
                // v1.5's backdrop behind its switch: one static wash, no
                // animated blobs. The colour still follows the artwork; only
                // the motion is gone.
                base
                    .overlay {
                        LinearGradient(
                            colors: [Color.black.opacity(0.10), Color.black.opacity(0.38)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .onAppear { base = ArtworkPalette.meshBlobs(from: artwork, seed: seed).base }
                    .onChange(of: seed) { _, new in
                        base = ArtworkPalette.meshBlobs(from: artwork, seed: new).base
                    }
                    .onChange(of: artwork) { _, data in
                        base = ArtworkPalette.meshBlobs(from: data, seed: seed).base
                    }
            } else {
                animatedMesh
            }
        }
    }

    private var legacyMesh: Bool {
        PlatformSettings.shared.getBoolean(key: "legacy_mesh_gradient", default: false)
    }

    private var animatedMesh: some View {
        let blobs = [blob0, blob1, blob2, blob3]
        return Canvas { context, size in
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
    var alignmentInProgress: Bool = false
    var onSeek: ((Double) -> Void)? = nil
    /// Absent where the caller has no track to translate, which is the case that
    /// matters: an empty lyric has nothing to translate and offering the control
    /// anyway is an invitation to a request that cannot succeed.
    var translator: LyricsTranslator?
    var trackId: String = ""
    /// The listener's timing correction, in milliseconds. See [LyricsOffsetBridge].
    var offsetMs: Int32 = 0
    var sourceVisible: Bool = true
    var onChangeSource: (() -> Void)? = nil
    var onRevealControls: (() -> Void)? = nil
    var onFocusLyrics: (() -> Void)? = nil
    /// True while the listener is scrolling the list themselves, which stands the
    /// auto-scroll down until they have been still for a moment.
    @State private var reading = false

    /// The clock the lyrics are judged against, which runs `offsetMs` behind the
    /// transport.
    ///
    /// Upstream's `adjustedLyricsPosition`, and the offset is applied *here*
    /// rather than by rewriting every line's timestamp on the way in. That is the
    /// whole design: the timings a source supplied stay exactly as supplied, so
    /// the transcript is the real one and a later fix to the offset is a change
    /// to one number rather than a re-fetch. A positive offset makes the adjusted
    /// clock smaller, so a line is reached later — which is what "positive shows
    /// lyrics later" means.
    private var adjustedPositionMs: Swift.Int64 {
        max(0, Swift.Int64(position * 1000) - Swift.Int64(offsetMs))
    }

    /// Every line being sung right now, which is usually one and is two across a
    /// duet.
    ///
    /// This used to be `lastIndex { $0.timeMs <= position }`, and that was wrong
    /// in a way nobody could report: a line that says when it ends lost its
    /// highlight the moment the *next* line's timestamp arrived, so the tail of a
    /// long line was never shown as sung — and a duet, where the answering vocal
    /// overlaps the lead, showed only one of the two. See [LyricFocus].
    private var activeRows: [Int] {
        // A Kotlin `List<Int>` arrives as `[KotlinInt]`, which Swift will not
        // index a `ForEach` with directly. Mapped here rather than by changing
        // the shared signature, because the shared side should say what it means
        // — a list of row numbers — and not what Swift can index.
        LyricFocus.shared
            .activeRows(lines: lines, positionMs: adjustedPositionMs)
            .map { Int(truncating: $0) }
    }

    /// Whether this document has real line or word timings. Plain-text lyric
    /// providers still have value; treating every line as an inactive timed row
    /// dimmed and blurred the entire transcript as if it were out of sync.
    private var hasSyncedTimings: Bool {
        LyricFocus.shared.isSynced(lines: lines)
    }

    /// Keep untimed rows crisp while incremental alignment is filling later
    /// lines in the same document.
    private func lineHasSyncedTimings(_ line: LyricLineDto, at index: Int) -> Bool {
        if line.timeMs > 0 || line.sungUntilMs != nil ||
            line.words.contains(where: { $0.startMs > 0 || $0.endMs > 0 }) ||
            (line.background?.timeMs ?? 0) > 0 ||
            line.background?.words.contains(where: { $0.startMs > 0 || $0.endMs > 0 }) == true
        {
            return true
        }
        // The first line may start at zero, which is also the DTO default for
        // unsynced text. A timed document gives that row a real zero timestamp.
        return index == 0 && hasSyncedTimings
    }

    /// The line the list scrolls to, and the one that is scaled up.
    private var leadIndex: Int {
        let lead = LyricFocus.shared.leadRow(lines: lines, positionMs: adjustedPositionMs)
        return lead < 0 ? 0 : min(Int(lead), max(0, lines.count - 1))
    }

    /// Where tapping a line should actually seek.
    ///
    /// The inverse of [adjustedPositionMs], and it has to be the inverse: a line
    /// whose nominal time is `t` is shown when the adjusted clock reaches `t`,
    /// which is transport position `t + offset`. Seeking to `t` instead would put
    /// the listener a line behind every time they tapped one.
    private func seekTarget(for line: LyricLineDto) -> Double {
        let ms = max(0, line.timeMs + Swift.Int64(offsetMs))
        return Double(ms) / 1000.0
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
                                        hasSyncedTimings: lineHasSyncedTimings(line, at: index),
                                        active: activeRows.contains(index),
                                        distance: abs(index - leadIndex),
                                        // The *adjusted* clock, the one the line
                                        // focus above already uses. Handing the
                                        // sweep the raw transport meant the
                                        // offset moved the line but not the
                                        // bright word, so touching the offset
                                        // control — the one gesture meant to
                                        // fix sync — put the two out of step.
                                        position: Double(adjustedPositionMs) / 1000,
                                        onTap: {
                                            if !sourceVisible {
                                                onRevealControls?()
                                            } else {
                                                onSeek?(seekTarget(for: line))
                                            }
                                        }
                                    )
                                    .id(index)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.never)
                        // Following the *lead* line rather than the last one that
                        // has started: across a duet those differ, and scrolling
                        // to the answer would push the lead off the top while it
                        // was still the line being sung.
                        .onAppear {
                            proxy.scrollTo(leadIndex, anchor: .center)
                        }
                        .onChange(of: trackId) { _, _ in
                            reading = false
                            proxy.scrollTo(leadIndex, anchor: .center)
                        }
                        .onChange(of: leadIndex) { _, index in
                            // Not while the listener is reading. A list that
                            // snaps back to the playhead as soon as they let go
                            // is a list nobody can look anything up in.
                            guard !reading else { return }
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        // The reader's own scroll stands the auto-scroll down
                        // until they have been still for a moment. This is a
                        // separate gesture rather than a `DragGesture` on the
                        // ScrollView so it does not compete with the scroll
                        // itself — simultaneous, and only asked whether a finger
                        // is down.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    reading = true
                                    // Advancing through the transcript (finger
                                    // moves up) gives the lyrics the whole view;
                                    // scrolling back reveals the deck again.
                                    if value.translation.height < -20, sourceVisible {
                                        onFocusLyrics?()
                                    } else if value.translation.height > 20, !sourceVisible {
                                        onRevealControls?()
                                    }
                                }
                                .onEnded { _ in
                                    withAnimation(.easeOut(duration: 1.6).delay(2.5)) {
                                        reading = false
                                    }
                                }
                        )
                    }
                    if sourceVisible, let credit = attribution {
                        HStack(spacing: 8) {
                            Text(credit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.72))
                            if let onChangeSource {
                                Button("Change", action: onChangeSource)
                                    .font(.subheadline.weight(.semibold))
                                    .underline()
                                    .foregroundStyle(.white)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attribution: String? {
        guard let sourceLabel, !sourceLabel.isEmpty else { return nil }
        if alignmentInProgress { return "Lyrics by \(sourceLabel) · aligning locally…" }
        guard hasSyncedTimings else { return "Lyrics by \(sourceLabel) · unsynced" }
        let lyricRows = lines.filter { !$0.isGap }
        let timedRows = lyricRows.enumerated().filter { lineHasSyncedTimings($0.element, at: $0.offset) }
        return timedRows.count == lyricRows.count
            ? "Lyrics by \(sourceLabel)"
            : "Lyrics by \(sourceLabel) · partially synced"
    }
}

private struct WordSyncedLine: View {
    let line: LyricLineDto
    let hasSyncedTimings: Bool
    let active: Bool
    let distance: Int
    let position: Double
    var onTap: (() -> Void)? = nil

    /// Which side of the panel this line is sung from.
    ///
    /// A duet reads as two people because the voices are on opposite sides, not
    /// because the words say so. A call-and-response laid out down one side is one
    /// long verse with no idea who is singing it.
    private var isSecondVoice: Bool {
        line.alignment == .end
    }

    var body: some View {
        VStack(alignment: isSecondVoice ? .trailing : .leading, spacing: 4) {
            Text(leadRendered)
                .font(.system(size: 34, weight: .bold, design: .default))
                .multilineTextAlignment(isSecondVoice ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                // The frame and the scale anchor follow the side as well. A second
                // voice that grew towards the left would lean out of its own column
                // the moment it was sung, which is the one moment the reader is
                // looking at it.
                .shadow(color: active ? .white.opacity(0.35) : .clear, radius: active ? 8 : 0, y: 0)
                .scaleEffect(active ? 1.04 : 1, anchor: isSecondVoice ? .trailing : .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
            if let backing = backingRendered {
                Text(backing)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .multilineTextAlignment(isSecondVoice ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }
            }
        }
        .opacity(hasSyncedTimings ? (active ? 1 : max(0.18, 0.58 - Double(distance) * 0.12)) : 0.9)
        .blur(radius: hasSyncedTimings && !active ? min(CGFloat(distance) * 1.15, 4) : 0)
        .animation(.easeInOut(duration: 0.2), value: active)
        .animation(.easeInOut(duration: 0.2), value: distance)
        .animation(.easeInOut(duration: 0.12), value: Int(position * 10))
    }

    private var split: (lead: String, backing: String?) {
        if let background = line.background, !background.text.isEmpty {
            return (line.text, background.text)
        }
        return Self.splitBackground(line.text)
    }

    private var leadRendered: AttributedString {
        render(text: split.lead, words: leadWords, glowing: hasSyncedTimings && active)
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
            s.font = .system(size: 34, weight: active ? .bold : .semibold, design: .default)
            s.foregroundColor = Color.white.opacity(active ? 1 : max(0.22, 0.55 - Double(distance) * 0.12))
            return s
        }
        let ms = Swift.Int64(position * 1000)
        var result = AttributedString()
        for (i, word) in words.enumerated() {
            var run = AttributedString(word.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))
            let sung = ms >= word.startMs
            let current = sung && ms < word.endMs
            run.font = .system(size: 34, weight: current ? .bold : .semibold, design: .default)
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

/// Upstream's lyrics-sources sheet lives in [LyricsLanguageSheet.swift] as
/// [LyricsSourcesSheet] (the fuller superset: try-order, PaxSeniX key,
/// word-sync preference, reset). The player's More menu presents that same
/// sheet rather than a local copy, so the two can never drift.

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
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context: Context) -> SquareRoutePicker {
        SquareRoutePicker()
    }
    func updateNSView(_ nsView: SquareRoutePicker, context: Context) {}
}

/// AVRoutePickerView's intrinsic size is not square, so toolbar glass becomes
/// a squircle. Pin it to a 22pt box so the item can be a circle.
final class SquareRoutePicker: NSView {
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

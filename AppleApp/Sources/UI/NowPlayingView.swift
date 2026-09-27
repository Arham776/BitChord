import SwiftUI
import BitChordShared
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
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
            LyricsSourcesSheet()
        }
        // The offset is adjusted *against the track playing*, so the effect has to
        // be visible while the sheet is still open — a control that only took
        // hold on the next track could not be aimed at anything.
        .onReceive(NotificationCenter.default.publisher(for: .lyricsOffsetChanged)) { _ in
            lyricsOffsetMs = LyricsOffsetBridge.offsetMs()
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
                    if pane == .main && !PlayerLayout.takesLandscapeShape(width: geo.size.width, height: geo.size.height) && fullBleedOn {
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
            // The artwork starts at the sheet's top edge, behind its grabber.
            // Output selection lives in the deck, as it does upstream.
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarTitleDisplayMode(.inline)
        }
    }
    #endif

    /// The shape test lives in [PlayerLayout] with the rest of the window rules,
    /// so the thresholds have one definition and can be checked without a window.

    /// The portrait player: stage above, pinned deck below.
    private var portraitPlayer: some View {
        VStack(spacing: 0) {
            stage
            if pane != .lyrics || lyricsControlsOpen {
                deck
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: lyricsControlsOpen)
    }

    /// The landscape player: two columns of equal width.
    ///
    /// The left one is the same in every pane — the sleeve, and under it the row
    /// that chooses which of the three the right column shows. The right one is
    /// that one thing. Nothing is drawn twice and nothing moves between columns,
    /// so opening the lyrics is only ever the right column's page being turned.
    private func landscapePlayer(size: CGSize) -> some View {
        // A phone on its side is short as well as wide, and the two are different
        // problems: a short window needs less gutter and a smaller sleeve, or the
        // row underneath gets pushed off the bottom.
        let compact = PlayerLayout.isCompactLandscape(width: size.width, height: size.height)
        let gutter = PlayerLayout.gutter(compact: compact)
        return HStack(spacing: 0) {
            VStack(spacing: compact ? 12 : 24) {
                // Square, and taking whichever axis runs out first once the row
                // below has had its height — measured, not estimated, so the row
                // underneath can never be pushed off the bottom.
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
                    // Credits, the lyric strip, the scrubber and the transport,
                    // in that order — the same deck as the portrait player with
                    // the artwork left out, because the left column already has it
                    // and nothing is drawn twice. The lyric strip stays: it is the
                    // one line of the words, and the pane it opens is the one this
                    // column can swap to.
                    VStack(spacing: 14) {
                        creditsRow
                        currentLyricStrip
                        positionControls
                        playerTransport
                    }
                    .transition(.opacity)
                case .lyrics, .queue:
                    panel
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: pane)
        }
        // Held to a maximum width and centred: a very wide window should not
        // stretch the columns into two narrow strips with a gulf between them.
        .frame(maxWidth: PlayerLayout.landscapeMaxWidth)
        .frame(maxWidth: .infinity)
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
                stageWidth: geo.size.width, stageHeight: geo.size.height
            )
            // Full-bleed is a phone idiom: only where the setting has anything
            // to act on, and never while a panel owns the stage.
            let hero = !collapsed && PlayerLayout.usesFullBleedArtwork(
                width: geo.size.width, preferenceEnabled: fullBleedOn
            )
            // iPad portrait panels present as a bottom drawer with a grabber
            // and swipe-to-close, upstream `PlayerDrawer`'s tablet treatment.
            let drawer = collapsed && PlayerLayout.presentsPanelDrawer(
                width: geo.size.width, height: geo.size.height
            )
            VStack(spacing: 0) {
                if pane == .lyrics {
                    lyricsHeader
                } else {
                    artworkStage(
                        side: collapsed ? PlayerLayout.sleeveCollapsedSide : (hero ? geo.size.width : full),
                        collapsed: collapsed,
                        hero: hero
                    )
                }
                if collapsed {
                    if drawer {
                        PlayerDrawerView(onDismiss: {
                            Haptics.play(.tap)
                            pane = .main
                        }) {
                            panel
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        panel
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// The open panel, filling whatever the collapsed sleeve has left.
    @ViewBuilder
    private var panel: some View {
        switch pane {
        case .main:
            Color.clear
        case .lyrics:
            LyricsPane(
                lines: controller.displayedLyrics,
                loading: controller.lyricsLoading,
                position: controller.position,
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: lyricsOffsetMs,
                sourceVisible: lyricsControlsOpen,
                onChangeSource: { showLyricsSources = true },
                onRevealControls: { revealLyricsControls() },
                onFocusLyrics: { hideLyricsControls() }
            )
        case .queue:
            UpNextPane()
        }
    }

    /// The pinned deck: credits, scrubber, transport, toggles.
    ///
    /// Measured at its natural height and fixed to the foot, so opening the
    /// lyrics does not shove the transport down. The pane toggles live here
    /// rather than floating over the artwork: they are *which pane* is showing,
    /// which is the same question the rest of this block answers.
    private var deck: some View {
        VStack(spacing: 14) {
            if pane != .lyrics { creditsRow }
            // The playback-origin caption / nerd line, hidden behind
            // `hide_song_status` exactly as upstream hides it.
            if pane != .lyrics, let status = songStatusLine {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(.horizontal, 24)
                    .accessibilityLabel(status)
            }
            // Upstream's deck is "lyric strip, scrubber, transport, volume,
            // toggles", and the strip is the first item: one line of the lyric
            // being sung right now, or the line saying why there is not one. It
            // stays on the player in every pane, so the words are there without
            // opening the lyrics at all.
            if pane != .lyrics { currentLyricStrip }
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

    /// Which of the three panes is showing.
    ///
    /// The artwork toggle is here rather than implied by the artwork's size: a
    /// control that only exists while a panel is closed cannot be used to open
    /// the first one, and one that only exists while a panel is open cannot be
    /// used to leave it.
    /// Lyrics and Up Next stay at the two ends, with Android's divided center
    /// capsule switching between output/party and shuffle/repeat/autoplay when
    /// the queue pane opens.
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
                    if pane == .queue {
                        queueModesPill
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    } else {
                        outputPartyPill
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                    Spacer(minLength: 0)
                    actionGlyph(.bchQueue, selected: pane == .queue, label: "Up Next") {
                        Haptics.play(.expand)
                        pane = pane == .queue ? .main : .queue
                    }
                }
                .padding(.horizontal, edgeInset)
            }
            .frame(height: 44)
            .animation(.easeInOut(duration: 0.2), value: pane == .queue)

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
            .accessibilityLabel(controller.autoplayEnabled ? "Autoplay on" : "Autoplay off")
        }
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private var pillDivider: some View {
        Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 44)
    }

    private var outputCaption: String {
        // Like upstream, identify the active output route here; do not surface
        // CoreAudio's internal device name for the built-in iPhone speaker.
        let routeName = controller.outputDevice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = routeName.lowercased()
        if controller.outputDevice.started, !routeName.isEmpty,
           !lowered.contains("iphone"), !lowered.contains("ipad"), !lowered.contains("built-in"),
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
    private var playerTransport: some View {
        HStack(spacing: 28) {
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
        if let conf = controller.analysisConfidence { parts.append(String(format: "%.0f%% mix", conf * 100)) }
        if controller.smartMixInProgress { parts.append("Automix") }
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
                                        active: activeRows.contains(index),
                                        distance: abs(index - leadIndex),
                                        position: position,
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
        return "Lyrics by \(sourceLabel)"
    }
}

private struct WordSyncedLine: View {
    let line: LyricLineDto
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

/// The Apple equivalent of upstream `PlayerDrawer`: the shell iPad portrait
/// panels present in — dark over the mesh, a grab handle, a title, drag down
/// to put it away. Used when the stage is iPad-portrait shaped (see
/// [PlayerLayout.presentsPanelDrawer]); phones keep the plain panel. The pane
/// buttons stay the primary way in and out — the drag only dismisses.
struct PlayerDrawerView<Content: View>: View {
    var title: String = "Up Next"
    var onDismiss: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drag: CGFloat = 0

    /// How far down the drawer has to be pulled before letting go dismisses
    /// it rather than springing back — upstream `DISMISS_DRAG_FRACTION`.
    private let dismissFraction: CGFloat = 0.25
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // The grab handle every sheet here has, and the thing that says
            // the drawer can be pulled away before anybody tries it.
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if reduceTransparency
                || PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false) {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(.rect(cornerRadius: 26, style: .continuous))
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    // Downward drag only: there is nothing above the drawer
                    // to reveal.
                    drag = max(0, value.translation.height)
                }
                .onEnded { value in
                    let threshold = height > 0 ? height * dismissFraction : 120
                    if value.translation.height > threshold {
                        Haptics.play(.tap)
                        onDismiss()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        drag = 0
                    }
                }
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(named: "Close panel", onDismiss)
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

import SwiftUI
import BitChordShared

/// The Apple Music-style playback pill (UI spec §3.1/§3.2), shared by both
/// platforms. Ports upstream's `MiniPlayer.kt`: artwork thumbnail (tap →
/// Now Playing), title/artist, transport. The pill is **always visible** —
/// with nothing playing it shows the empty state, exactly as Music keeps its
/// bottom pill around. The macOS variant carries Music's full cluster:
/// shuffle / prev / play / next / repeat on the left, lyrics + volume right.
struct PlaybackPill: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        #if os(macOS)
        macOSPill
        #else
        iOSPill
        #endif
    }

    // ---- iOS: mini-player above the tab bar --------------------------------
    #if os(iOS)
    private var iOSPill: some View {
        HStack(spacing: 12) {
            artworkOrPlaceholder
            info
            Spacer(minLength: 4)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chromeFill)
        }
        .overlay(alignment: .bottom) { progressHairline }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
        .modifier(NowPlayingZoomSource())
        .onTapGesture { appModel.nowPlayingPresented = true }
    }
    #endif

    // ---- macOS: Music's floating glass pill --------------------------------
    #if os(macOS)
    private var macOSPill: some View {
        HStack(spacing: 18) {
            HStack(spacing: 4) {
                pillButton("Shuffle", icon: .bchShuffle) {
                    controller.toggleShuffle()
                }
                .foregroundStyle(controller.shuffleEnabled ? Color.accentColor : .primary)

                pillButton("Previous", system: "backward.fill") {
                    controller.previous()
                }
                .disabled(!controller.canPlayPrevious)

                if controller.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 32, height: 32)
                        .help("Loading")
                } else {
                    pillButton(
                        controller.isPlaying ? "Pause" : "Play",
                        system: controller.isPlaying ? "pause.fill" : "play.fill",
                        glyph: 17
                    ) {
                        controller.togglePlayPause()
                    }
                    .disabled(controller.current == nil)
                }

                pillButton("Next", system: "forward.fill") {
                    controller.next()
                }
                .disabled(!controller.canPlayNext)

                Button {
                    controller.cycleRepeat()
                } label: {
                    RepeatGlyph(mode: controller.repeatMode, size: 15)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.repeatMode == .off ? .primary : Color.accentColor)
                .help(controller.repeatMode == .one ? "Repeat one" : controller.repeatMode == .all ? "Repeat all" : "Repeat off")
            }
            .foregroundStyle(.primary)

            MacNowPlayingSlot(
                artwork: { artworkOrPlaceholder },
                info: { info }
            )
            .frame(minWidth: 180, maxWidth: 360)

            Button {
                appModel.nowPlayingPresented = true
            } label: {
                Image(.bchLyrics)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Lyrics")

            if !controller.hideVolumeBar {
                PillSlider(volume: Binding(
                    get: { controller.volume },
                    set: { controller.volume = $0 }
                ))
                .frame(width: 128)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(chromeFill)
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shared 32pt hit target; glyphs sit at 15pt so shuffle, skip and
    /// repeat weigh the same. Play is the one exception, one step larger.
    private func pillButton(
        _ label: String,
        icon: ImageResource? = nil,
        system: String? = nil,
        glyph: CGFloat = 15,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).resizable().scaledToFit().frame(width: glyph, height: glyph)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: glyph, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
    }
    #endif

    // ---- Shared pieces ------------------------------------------------------

    @ViewBuilder
    private var artworkOrPlaceholder: some View {
        if controller.current != nil {
            ArtworkView(entry: controller.current, side: 34)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                .id(controller.current?.id)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.6))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(.bchMusicNote)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.current?.title ?? "Not Playing")
                .font(.callout.weight(.semibold))
                .foregroundStyle(controller.current == nil ? .secondary : .primary)
                .lineLimit(1)
            Text(controller.current?.artist ?? "Music you start appears here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var reduceBlur: Bool {
        PlatformSettings.shared.getBoolean(key: "reduce_dynamic_blur", default: false)
    }

    /// The pill's fill, honouring both the app's own preference and the system's.
    ///
    /// Two settings, and the difference matters: `reduce_dynamic_blur` is a
    /// preference *this app* offers and someone can turn it off, while Reduce
    /// Transparency is a system accessibility setting that applies to every
    /// translucent surface on the device. Reading only the first — which is what
    /// this did — left the pill as the one surface in the app that stayed
    /// translucent for someone who had asked the system, everywhere, for it not to
    /// be.
    private var chromeFill: AnyShapeStyle {
        if reduceTransparency || reduceBlur {
            return AnyShapeStyle(Color.primary.opacity(0.12))
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    /// Progress hairline hugging the iOS mini-player's bottom edge.
    private var progressHairline: some View {
        GeometryReader { geo in
            let progress = controller.duration > 0
                ? controller.position / controller.duration
                : 0
            Capsule()
                .fill(.tertiary)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    #if os(iOS)
    private var buttons: some View {
        HStack(spacing: 18) {
            Button {
                controller.togglePlayPause()
            } label: {
                if controller.isBuffering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.current == nil && !controller.isBuffering)

            Button {
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayNext)
        }
        .foregroundStyle(.primary)
    }
    #endif
}

#if os(macOS)
/// The now-playing slot inside the original pill chrome. At rest: artwork +
/// title, with a 2pt seek line only as wide as this slot. Hover: that line
/// thickens and the times replace the artwork, without touching the pill shape.
private struct MacNowPlayingSlot<Artwork: View, Info: View>: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var info: Info

    @State private var hovering = false
    @State private var dragging = false

    init(@ViewBuilder artwork: () -> Artwork, @ViewBuilder info: () -> Info) {
        self.artwork = artwork()
        self.info = info()
    }

    private var scrubbing: Bool { (hovering || dragging) && controller.duration > 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 10) {
                artwork
                info
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .opacity(scrubbing ? 0.35 : 1)
            .blur(radius: scrubbing ? 1.5 : 0)
            .allowsHitTesting(!scrubbing)
            .contentShape(.rect)
            .onTapGesture { appModel.nowPlayingPresented = true }

            if controller.duration > 0 {
                VStack(spacing: 3) {
                    if scrubbing {
                        HStack {
                            Text(clock(controller.position))
                            Spacer(minLength: 0)
                            Text(clock(max(controller.duration - controller.position, 0), remaining: true))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    SlotSeekLine(
                        progress: min(max(controller.position / controller.duration, 0), 1),
                        thick: scrubbing,
                        onSeek: { fraction in
                            controller.seek(to: fraction * controller.duration)
                        },
                        onDragging: { dragging = $0 }
                    )
                }
                .contentShape(.rect)
                .onHover { hovering = $0 }
            }
        }
        .frame(height: 44)
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: scrubbing)
    }

    private func clock(_ seconds: Double, remaining: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return remaining ? "-0:00" : "0:00" }
        let total = Int(seconds.rounded(.down))
        let body = "\(total / 60):\(String(format: "%02d", total % 60))"
        return remaining ? "-\(body)" : body
    }
}

private struct SlotSeekLine: View {
    var progress: Double
    var thick: Bool
    var onSeek: (Double) -> Void
    var onDragging: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = thick ? 8 : 2
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(thick ? 0.28 : 0.18))
                Capsule()
                    .fill(.primary.opacity(thick ? 0.95 : 0.55))
                    .frame(width: max(0, w * min(max(progress, 0), 1)))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onDragging(true)
                        onSeek(min(max(g.location.x / max(w, 1), 0), 1))
                    }
                    .onEnded { _ in onDragging(false) }
            )
        }
        .frame(height: 8)
    }
}
#endif

/// Slim volume slider — hairline capsule track with a small knob, in the
/// spirit of upstream's `ThinSlider`. Adapts to the surrounding foreground
/// style (dark Now Playing backdrop vs. light pill).
struct PillSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * volume
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: max(4, x), height: 4)
                    Circle()
                        .fill(.primary)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(0, x - 5), w - 10))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            volume = min(max(0, g.location.x / w), 1)
                        }
                )
            }
            .frame(height: 14)
        }
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
/// WWDC 323: the mini player is the zoom source for the Now Playing sheet.
private struct NowPlayingZoomSource: ViewModifier {
    @Environment(\.nowPlayingZoomNamespace) private var zoomNamespace

    func body(content: Content) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: NowPlayingZoom.sourceID, in: zoomNamespace)
        } else {
            content
        }
    }
}
#endif


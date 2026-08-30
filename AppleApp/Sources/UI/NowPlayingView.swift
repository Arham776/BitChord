import SwiftUI
import BitChordShared

/// Full Now Playing (UI spec §3.3). On macOS this is the full-window
/// in-place takeover: artwork left with title beneath, transport below, a
/// lyrics pane filling the right half ("Play a song to see lyrics here." when
/// empty), volume top-right, dismiss top-left. On iOS it is a full-screen
/// cover. Background is an animated `MeshGradient` driven by the artwork's
/// palette (native iOS 18 / macOS 15 API per the raised floor).
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // ---- macOS: full-window takeover ---------------------------------------
    #if os(macOS)
    private var macOSBody: some View {
        ZStack {
            MeshBackdrop(seed: controller.current?.id.hashValue ?? 0)
                .ignoresSafeArea()
                .id(controller.current?.id)
            HStack(spacing: 0) {
                // Left column: artwork, metadata, transport.
                VStack(spacing: 16) {
                    HStack {
                        Button {
                            appModel.nowPlayingPresented = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 24)

                    ArtworkView(entry: controller.current)
                        .frame(maxWidth: 340, maxHeight: 340)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                        .scaleEffect(controller.isPlaying ? 1 : 0.86)
                        .animation(.spring(response: 0.55, dampingFraction: 0.68), value: controller.isPlaying)
                        .id(controller.current?.id)

                    VStack(spacing: 6) {
                        Text(controller.current?.title ?? "Nothing playing")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(controller.current?.artist ?? "")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    transport
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)

                // Right column: lyrics pane.
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        PillSlider(volume: Binding(
                            get: { controller.volume },
                            set: { controller.volume = $0 }
                        ))
                        .foregroundStyle(.white)
                        .frame(width: 150)
                        .padding(.trailing, 24)
                    }
                    Spacer()
                    LyricsPane(
                        lines: controller.lyrics,
                        loading: controller.lyricsLoading,
                        position: controller.position,
                        hasTrack: controller.current != nil
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    #endif

    // ---- iOS: full-screen cover --------------------------------------------
    #if os(iOS)
    private var iOSBody: some View {
        ZStack {
            MeshBackdrop(seed: controller.current?.id.hashValue ?? 0)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                HStack {
                    Button {
                        appModel.nowPlayingPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)

                ArtworkView(entry: controller.current, side: 300)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 24, y: 12)
                    .scaleEffect(controller.isPlaying ? 1 : 0.86)
                    .animation(.spring(response: 0.55, dampingFraction: 0.68), value: controller.isPlaying)
                    .id(controller.current?.id)

                VStack(spacing: 6) {
                    Text(controller.current?.title ?? "Nothing playing")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text(controller.current?.artist ?? "")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                }

                positionControls
                    .padding(.horizontal, 32)
                transport
                Spacer(minLength: 20)
            }
        }
    }
    #endif

    // ---- Shared pieces ------------------------------------------------------

    private var positionControls: some View {
        VStack(spacing: 6) {
            ThinSlider(
                value: controller.position,
                maximum: controller.duration
            ) { controller.seek(to: $0) }
            .tint(.white.opacity(0.9))

            HStack {
                Text(Self.timestamp(controller.position))
                Spacer()
                Text(Self.timestamp(controller.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var transport: some View {
        HStack(spacing: 30) {
            Button {
                controller.cycleRepeat()
            } label: {
                ZStack {
                    Image(.bchRepeat)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 19)
                    if controller.repeatMode == .one {
                        Text("1")
                            .font(.system(size: 8, weight: .bold))
                            .offset(y: 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.repeatMode == .off ? .white.opacity(0.7) : .white)
            .help(controller.repeatMode == .one ? "Repeat one" : controller.repeatMode == .all ? "Repeat all" : "Repeat off")

            Button {
                controller.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20, weight: .bold))
            }
            .buttonStyle(.plain)

            Button {
                controller.togglePlayPause()
            } label: {
                if controller.isBuffering {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                } else {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                }
            }
            .buttonStyle(.plain)

            Button {
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .bold))
            }
            .buttonStyle(.plain)

            Button {
                controller.toggleShuffle()
            } label: {
                Image(.bchShuffle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.shuffleEnabled ? .white : .white.opacity(0.7))
            .help(controller.shuffleEnabled ? "Shuffle on" : "Shuffle off")
        }
        .foregroundStyle(.white)
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
}

/// Animated `MeshGradient` backdrop (UI spec §7) — gently drifting control
/// points over a palette implied by the artwork hue. Upstream's
/// `MeshGradient.kt`/`CanvasArtworkPlayer.kt` equivalent.
struct MeshBackdrop: View {
    var seed: Int

    var body: some View {
        let palette = Self.palette(seed: seed)
        TimelineView(.animation) { timeline in
            let cycle = 12.5
            let t = Float(
                timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycle) / cycle
            )
            MeshGradient(width: 3, height: 3, points: Self.points(t: t), colors: palette)
                .ignoresSafeArea()
        }
    }

    static func points(t: Float) -> [SIMD2<Float>] {
        let wobble = sin(t * .pi * 2) * 0.06
        return [
            [0, 0], [0.5, -wobble * 0.3], [1, 0],
            [-wobble * 0.4, 0.5], [0.5 + wobble, 0.5], [1 + wobble * 0.4, 0.5],
            [0, 1], [0.5, 1 + wobble * 0.3], [1, 1],
        ]
    }

    /// Deterministic per-track deep-tone palette.
    static func palette(seed: Int) -> [Color] {
        let base = Double(abs(seed) % 360)
        func hsl(_ offset: Double, _ s: Double, _ l: Double) -> Color {
            let hue = (base + offset).truncatingRemainder(dividingBy: 360) / 360
            return Color(hue: hue, saturation: s, brightness: l)
        }
        return [
            hsl(0, 0.65, 0.10), hsl(30, 0.60, 0.14), hsl(60, 0.55, 0.10),
            hsl(330, 0.55, 0.13), hsl(0, 0.70, 0.18), hsl(120, 0.45, 0.12),
            hsl(210, 0.60, 0.08), hsl(180, 0.55, 0.13), hsl(300, 0.50, 0.09),
        ]
    }
}

/// Upstream's lyrics strip: the current line is bright, others recede.
struct LyricsPane: View {
    var lines: [LyricLineDto]
    var loading: Bool
    var position: Double
    var hasTrack: Bool

    private var activeIndex: Int {
        let ms = Int64(position * 1000)
        return lines.lastIndex { $0.timeMs <= ms } ?? 0
    }

    var body: some View {
        Group {
            if !hasTrack {
                Text("Play a song to see lyrics here.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            } else if loading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else if lines.isEmpty {
                Text("No lyrics for this track.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title3.weight(index == activeIndex ? .bold : .regular))
                                    .foregroundStyle(.white.opacity(index == activeIndex ? 1 : 0.38))
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: activeIndex) { _, index in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

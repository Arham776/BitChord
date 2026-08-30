import SwiftUI

/// The Apple Music-style playback pill (UI spec §3.1/§3.2), shared by both
/// platforms. Ports upstream's `MiniPlayer.kt`: artwork thumbnail (tap →
/// Now Playing), title/artist, transport. The pill is **always visible** —
/// with nothing playing it shows the empty state, exactly as Music keeps its
/// bottom pill around. The macOS variant carries Music's full cluster:
/// shuffle / prev / play / next / repeat on the left, lyrics + volume right.
struct PlaybackPill: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel

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
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) { progressHairline }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { appModel.nowPlayingPresented = true }
    }
    #endif

    // ---- macOS: Music's floating glass pill --------------------------------
    #if os(macOS)
    private var macOSPill: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                pillButton("Shuffle", icon: .bchShuffle, width: 16) {
                    controller.toggleShuffle()
                }
                .foregroundStyle(controller.shuffleEnabled ? Color.accentColor : .primary)
                pillButton("Previous", system: "backward.fill", size: 13) {
                    controller.previous()
                }
                .disabled(!controller.canPlayPrevious)

                if controller.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                        .help("Loading")
                } else {
                    pillButton(controller.isPlaying ? "Pause" : "Play", system: controller.isPlaying ? "pause.fill" : "play.fill", size: 15) {
                        controller.togglePlayPause()
                    }
                    .disabled(controller.current == nil)
                }

                pillButton("Next", system: "forward.fill", size: 13) {
                    controller.next()
                }
                .disabled(!controller.canPlayNext)

                pillButton("Repeat", icon: .bchRepeat, width: 16) {
                    controller.cycleRepeat()
                }
                .foregroundStyle(controller.repeatMode == .off ? .primary : Color.accentColor)
                .help(controller.repeatMode == .one ? "Repeat one" : controller.repeatMode == .all ? "Repeat all" : "Repeat off")
            }
            .foregroundStyle(.primary)

            Button {
                appModel.nowPlayingPresented = true
            } label: {
                HStack(spacing: 10) {
                    artworkOrPlaceholder
                    info
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button {
                appModel.nowPlayingPresented = true
            } label: {
                Image(.bchLyrics)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Lyrics")

            PillSlider(volume: Binding(
                get: { controller.volume },
                set: { controller.volume = $0 }
            ))
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottom) { progressHairline }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func pillButton(_ label: String, icon: ImageResource? = nil, system: String? = nil, width: CGFloat = 0, size: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).resizable().scaledToFit().frame(width: width)
                } else if let system {
                    Image(systemName: system).font(.system(size: size, weight: .bold))
                }
            }
            .frame(width: 22)
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

    /// Progress hairline hugging the pill's bottom edge, clipped by the pill
    /// shape so it follows the rounded corners.
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

/// Slim volume slider — hairline capsule track with a small knob, in the
/// spirit of upstream's `ThinSlider`. Adapts to the surrounding foreground
/// style (dark Now Playing backdrop vs. light pill).
struct PillSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
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

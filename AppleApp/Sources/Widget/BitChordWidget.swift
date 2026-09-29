import SwiftUI
import WidgetKit
import AppIntents
#if os(iOS)
import ActivityKit
#endif

// The §9 widget, snapshot-driven per the parity contract: ready-to-play
// state with no position, prev/next availability dimmed not removed, dark
// gradient placeholder when there is no art, single-entry timeline pushed by
// WidgetStatePublisher. The extension never links native-core and never
// touches the network. Tapping opens the player (deep link §9).

private let groupDefaults = UserDefaults(suiteName: "group.com.example.bitchord")

struct MediaWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let playing: Bool
    let canNext: Bool
    let canPrevious: Bool
    let artwork: Data?
    let hasSession: Bool

    /// Upstream's last-played fallback: the widget is never blank after a
    /// first play, so an empty snapshot renders the placeholder, not nothing.
    static let empty = MediaWidgetEntry(
        date: .now, title: "BitChord", artist: "Nothing queued",
        playing: false, canNext: false, canPrevious: false,
        artwork: nil, hasSession: false
    )
}

struct MediaWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MediaWidgetEntry { snapshot() }

    func getSnapshot(in context: Context, completion: @escaping (MediaWidgetEntry) -> Void) {
        completion(snapshot())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MediaWidgetEntry>) -> Void) {
        // Single entry: freshness is push-driven by WidgetStatePublisher's
        // reloadTimelines, never polled (spec §9).
        completion(Timeline(entries: [snapshot()], policy: .never))
    }

    private func snapshot() -> MediaWidgetEntry {
        guard let defaults = groupDefaults, let title = defaults.string(forKey: "widget.title") else {
            return .empty
        }
        return MediaWidgetEntry(
            date: .now,
            title: title,
            artist: defaults.string(forKey: "widget.artist") ?? "",
            playing: defaults.bool(forKey: "widget.playing"),
            canNext: defaults.bool(forKey: "widget.canNext"),
            canPrevious: defaults.bool(forKey: "widget.canPrevious"),
            artwork: defaults.string(forKey: "widget.artworkPath").flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
            hasSession: true
        )
    }
}

struct MediaWidgetView: View {
    var entry: MediaWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "bitchord://open-player"))
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if entry.hasSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    artwork
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Image(systemName: entry.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(entry.playing ? "Playing" : "Ready to play")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(entry.playing ? Color.accentColor : .secondary)
                    }
                    Spacer(minLength: 0)
                }
                if family != .systemSmall {
                    HStack(spacing: 16) {
                        Button(intent: WidgetTransportIntent(command: "previous")) {
                            Image(systemName: "backward.fill")
                        }
                        .disabled(!entry.canPrevious)
                        Button(intent: WidgetTransportIntent(command: "toggle")) {
                            Image(systemName: entry.playing ? "pause.fill" : "play.fill")
                        }
                        Button(intent: WidgetTransportIntent(command: "next")) {
                            Image(systemName: "forward.fill")
                        }
                        .disabled(!entry.canNext)
                        Spacer(minLength: 0)
                    }
                    .font(.title3)
                    .tint(.primary)
                }
            }
            .padding(4)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Text("BitChord")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = entry.artwork, let image = platformImage(data) {
            Image(platform: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.10, blue: 0.16),
                             Color(red: 0.05, green: 0.05, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

#if os(macOS)
private func platformImage(_ data: Data) -> NSImage? { NSImage(data: data) }
private extension Image {
    init(platform image: NSImage) { self.init(nsImage: image) }
}
#else
private func platformImage(_ data: Data) -> UIImage? { UIImage(data: data) }
private extension Image {
    init(platform image: UIImage) { self.init(uiImage: image) }
}
#endif

struct BitChordMediaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BitChordMediaWidget", provider: MediaWidgetProvider()) { entry in
            MediaWidgetView(entry: entry)
        }
        .configurationDisplayName("BitChord")
        .description("Now-playing state, transport controls, and a tap back into the player.")
        // systemSmall ~= upstream square, systemMedium ~= upstream wide (spec §9).
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BitChordWidgetBundle: WidgetBundle {
    var body: some Widget {
        BitChordMediaWidget()
#if os(iOS)
        BitChordNowPlayingLiveActivity()
#endif
    }
}

#if os(iOS)
@available(iOSApplicationExtension 16.1, *)
struct BitChordNowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            NowPlayingActivityLockScreen(state: context.state)
                .activityBackgroundTint(Color(red: 0.09, green: 0.08, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "bitchord://open-player"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityArtwork(path: context.state.artworkPath)
                        .frame(width: 42, height: 42)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: WidgetTransportIntent(command: "toggle")) {
                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(context.state.isPlaying ? "Pause" : "Play")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 22) {
                        Button(intent: WidgetTransportIntent(command: "previous")) {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.plain)
                        LiveActivityProgress(state: context.state)
                        Button(intent: WidgetTransportIntent(command: "next")) {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.title3)
                    .tint(.white)
                }
            } compactLeading: {
                LiveActivityArtwork(path: context.state.artworkPath)
                    .frame(width: 18, height: 18)
                    .clipShape(.circle)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "play.fill")
                    .font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: "music.note")
            }
            .widgetURL(URL(string: "bitchord://open-player"))
            .keylineTint(.accentColor)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct NowPlayingActivityLockScreen: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            LiveActivityArtwork(path: state.artworkPath)
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LiveActivityProgress(state: state)
            }
            Spacer(minLength: 4)
            HStack(spacing: 15) {
                Button(intent: WidgetTransportIntent(command: "previous")) {
                    Image(systemName: "backward.fill")
                }
                .accessibilityLabel("Previous")
                Button(intent: WidgetTransportIntent(command: "toggle")) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                Button(intent: WidgetTransportIntent(command: "next")) {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .tint(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .foregroundStyle(.white)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityProgress: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        Group {
            if let interval = state.progressInterval {
                ProgressView(timerInterval: interval, countsDown: false)
            } else {
                ProgressView(value: state.duration > 0 ? state.displayedPosition / state.duration : 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .accessibilityLabel("Playback progress")
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityArtwork: View {
    let path: String?

    var body: some View {
        if let path,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.16, blue: 0.27),
                             Color(red: 0.07, green: 0.06, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}
#endif

struct WidgetTransportIntent: AppIntent {
    static var title: LocalizedStringResource = "BitChord Transport"
    static var isDiscoverable = false

    @Parameter(title: "Command")
    var command: String

    init() { command = "toggle" }
    init(command: String) { self.command = command }

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.com.example.bitchord")?.set(command, forKey: "widget.command")
        return .result()
    }
}

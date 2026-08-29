import SwiftUI
import WidgetKit

// Milestone-1 scaffold of the §9 widget: placeholder provider + families only.
// Real snapshot rendering (App Group state), transport App Intents, and the
// deep link land at milestone 13. The extension never links native-core.

struct MediaWidgetEntry: TimelineEntry {
    let date: Date
}

struct MediaWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MediaWidgetEntry {
        MediaWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MediaWidgetEntry) -> Void) {
        completion(MediaWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MediaWidgetEntry>) -> Void) {
        // Single-entry timeline; freshness is push-driven by WidgetStatePublisher
        // (spec §3.2) calling WidgetCenter.reloadTimelines — no polling.
        completion(Timeline(entries: [MediaWidgetEntry(date: .now)], policy: .never))
    }
}

struct MediaWidgetView: View {
    var entry: MediaWidgetEntry

    var body: some View {
        VStack(spacing: 4) {
            Text("BitChord")
                .font(.headline)
            Text("Widget scaffold — snapshot state will come from the App Group (spec §9).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

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
    }
}

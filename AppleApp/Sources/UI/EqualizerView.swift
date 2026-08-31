import SwiftUI
import BitChordShared

struct EqualizerView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var bands: [Double] = EqualizerView.load()
    private static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Ten-band EQ on the mixed output. Flat is sample-identical passthrough.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<10, id: \.self) { i in
                    VStack {
                        Slider(value: $bands[i], in: -12...12, step: 0.5)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 120, height: 28)
                        Text(Self.labels[i]).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 180)
            .padding()
            Button("Reset", role: .none) { bands = Array(repeating: 0, count: 10) }
            Spacer()
        }
        .navigationTitle("Equalizer")
        .onChange(of: bands) { _, _ in persist() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 280)
        #endif
    }

    private func persist() {
        let csv = bands.map { String(format: "%.1f", $0) }.joined(separator: ",")
        AppSettings.shared.setEqGains(value: csv)
        controller.updateEq(bands.map { Float($0) })
    }

    static func load() -> [Double] {
        let raw = PlatformSettings.shared.getString(key: "eq_gains", default: "0,0,0,0,0,0,0,0,0,0")
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if parts.count == 10 { return parts }
        return Array(repeating: 0, count: 10)
    }
}

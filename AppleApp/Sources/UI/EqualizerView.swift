import SwiftUI
import BitChordShared
#if os(iOS)
import UIKit
#endif

/// The ten-slot equaliser curve the engine expects — slots 0..6 the manual tab,
/// slots 7..9 the tone pad, exactly upstream `EqLayout` / `manualCurve` /
/// `toneCurve`. The make-up preamp is computed in the engine, never here.
enum EqualizerTuning {
    static let slots = 10
    static let manualBandsHz: [Double] = [60, 150, 400, 1_000, 2_500, 6_000, 14_000]
    static let manualQ = 1.0
    static let manualRangeDb = 12.0
    static let toneLow = 7
    static let toneMid = 8
    static let toneHigh = 9
    static let toneSteps = 5
    static let toneDbPerStep = 1.2

    /// The stored seven manual bands. `nonisolated` so the engine-startup task
    /// can read the tuning without hopping to the main actor.
    nonisolated static func loadBands() -> [Double] {
        let raw = PlatformSettings.shared.getString(key: "equalizer_bands", default: "0,0,0,0,0,0,0")
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if parts.count == 7 { return parts }
        return Array(repeating: 0, count: 7)
    }

    static func manualCurve(_ bands: [Double]) -> (gains: [Double], qs: [Double]) {
        var gains = Array(repeating: 0.0, count: slots)
        var qs = Array(repeating: 0.707, count: slots)
        for band in 0..<7 {
            let value = bands.indices.contains(band) ? bands[band] : 0
            gains[band] = min(max(value, -manualRangeDb), manualRangeDb)
            qs[band] = manualQ
        }
        return (gains, qs)
    }

    static func toneCurve(x: Int, y: Int, focused: Bool) -> (gains: [Double], qs: [Double]) {
        var gains = Array(repeating: 0.0, count: slots)
        var qs = Array(repeating: 0.707, count: slots)
        let tilt = Double(min(max(x, -toneSteps), toneSteps)) * toneDbPerStep
        let contour = Double(min(max(y, -toneSteps), toneSteps)) * toneDbPerStep
        gains[toneLow] = -tilt
        gains[toneHigh] = tilt
        gains[toneMid] = contour
        let shelfQ = focused ? 0.9 : 0.5
        let bellQ = focused ? 2.2 : 0.7
        qs[toneLow] = shelfQ
        qs[toneHigh] = shelfQ
        qs[toneMid] = bellQ
        return (gains, qs)
    }
}

/// Apple port of upstream `EqualizerScreen`: a dynamic tone pad, a seven-band
/// manual tab with presets, and a balance trim.
///
/// Upstream drives one ten-slot filter cascade (`EqLayout`) from two tabs, and
/// so does this: the tab is a way of describing a curve, not different audio
/// machinery. The engine receives the same ten-slot gains + Qs either way, so
/// switching tabs or presets glides rather than clicks.
struct EqualizerView: View {
    enum Mode: String, CaseIterable {
        case dynamic = "Dynamic"
        case manual = "Manual"
    }

    @Environment(PlaybackController.self) private var controller
    @State private var enabled = PlatformSettings.shared.getBoolean(key: "equalizer_enabled", default: false)
    @State private var mode = Mode(rawValue: PlatformSettings.shared.getString(key: "equalizer_mode", default: "Dynamic")) ?? .dynamic
    @State private var bands: [Double] = EqualizerTuning.loadBands()
    @State private var toneX = Int(PlatformSettings.shared.getInt(key: "equalizer_tone_x", default: 0))
    @State private var toneY = Int(PlatformSettings.shared.getInt(key: "equalizer_tone_y", default: 0))
    @State private var focused = PlatformSettings.shared.getBoolean(key: "equalizer_focused", default: false)
    @State private var balance = Double(PlatformSettings.shared.getFloat(key: "equalizer_balance", default: 0))
    @State private var presetName = PlatformSettings.shared.getString(key: "equalizer_preset", default: "Flat")
    private static let labels = ["60", "150", "400", "1k", "2.5k", "6k", "14k"]

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Equalizer", isOn: $enabled)
                .font(.headline)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    switch mode {
                    case .dynamic:
                        DynamicEQPad(
                            x: $toneX, y: $toneY, focused: $focused, enabled: enabled,
                            onChange: applyDynamic
                        )
                    case .manual:
                        presetRow
                        manualBands
                    }
                    balanceControl
                }
                .padding(.top, 12)
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("Equalizer")
        .onChange(of: enabled) { _, value in
            PlatformSettings.shared.putBoolean(key: "equalizer_enabled", value: value)
            applyCurrent()
        }
        .onChange(of: mode) { _, value in
            PlatformSettings.shared.putString(key: "equalizer_mode", value: value.rawValue)
            applyCurrent()
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    // MARK: - Manual tab

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preset")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQPresets.all, id: \.name) { preset in
                        Button {
                            presetName = preset.name
                            bands = preset.gains
                            persistManual(presetName: preset.name)
                        } label: {
                            Text(preset.name)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(preset.name == presetName ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(preset.name == presetName ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            Text("Seven-band parametric EQ with shelves at both ends. Flat is sample-identical passthrough.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private var manualBands: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    VStack {
                        Text(Self.formatGain(bands[i]))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(abs(bands[i]) < 0.05 ? Color.secondary : Color.accentColor)
                        Slider(value: $bands[i], in: -12...12, step: 0.5)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 120, height: 28)
                        Text(Self.labels[i]).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 200)
            .padding(.horizontal, 4)
            Button("Reset") {
                presetName = "Flat"
                bands = Array(repeating: 0, count: 7)
                persistManual(presetName: "Flat")
            }
        }
        .onChange(of: bands) { _, _ in persistManual(presetName: EQPresets.matching(bands)) }
    }

    private var balanceControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)
            HStack(spacing: 10) {
                Text("L").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: $balance, in: -1...1, step: 0.01)
                Text("R").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .onChange(of: balance) { _, value in
                PlatformSettings.shared.putFloat(key: "equalizer_balance", value: Float(value))
                applyCurrent()
            }
        }
    }

    // MARK: - Applying

    private func persistManual(presetName: String) {
        self.presetName = presetName
        PlatformSettings.shared.putString(key: "equalizer_preset", value: presetName)
        let csv = bands.map { String(format: "%.1f", $0) }.joined(separator: ",")
        PlatformSettings.shared.putString(key: "equalizer_bands", value: csv)
        applyCurrent()
    }

    private func applyDynamic() {
        PlatformSettings.shared.putInt(key: "equalizer_tone_x", value: Int32(toneX))
        PlatformSettings.shared.putInt(key: "equalizer_tone_y", value: Int32(toneY))
        PlatformSettings.shared.putBoolean(key: "equalizer_focused", value: focused)
        PlatformSettings.shared.putString(key: "equalizer_preset", value: "Dynamic")
        applyCurrent()
    }

    private func applyCurrent() {
        controller.applyEqualizer()
    }

    static func formatGain(_ value: Double) -> String {
        if abs(value) < 0.05 { return "0" }
        if value == value.rounded() { return value > 0 ? "+\(Int(value))" : "\(Int(value))" }
        return String(format: value > 0 ? "+%.1f" : "%.1f", value)
    }
}

// MARK: - Dynamic tone pad

/// Upstream `TonePad`: one puck over a dot grid.
///
/// X tilts the spectrum warm (left) ↔ bright (right) at 1.2 dB per step with
/// the middle held level — the low shelf and high shelf move by the same amount
/// in opposite directions. Y contours the mids: down scoops them into a V, up
/// pushes them forward. Broad/Focused narrows the three shapes' bandwidth, and
/// is the only thing it changes.
struct DynamicEQPad: View {
    @Binding var x: Int
    @Binding var y: Int
    @Binding var focused: Bool
    var enabled: Bool
    var onChange: () -> Void

    private static let steps = 5
    private static let padHeight: CGFloat = 230

    var body: some View {
        VStack(spacing: 10) {
            Text("Drag the puck: sideways tilts warm ↔ bright, up and down shapes the mids.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            GeometryReader { geo in
                Canvas { context, size in
                    let inset: CGFloat = 19
                    let usableW = max(size.width - inset * 2, 1)
                    let usableH = max(size.height - inset * 2, 1)
                    let columns = Self.steps * 2
                    for column in 0...columns {
                        for row in 0...columns {
                            let onAxis = column == Self.steps || row == Self.steps
                            let center = CGPoint(
                                x: inset + usableW * CGFloat(column) / CGFloat(columns),
                                y: inset + usableH * CGFloat(row) / CGFloat(columns)
                            )
                            context.fill(
                                Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)),
                                with: .color(.secondary.opacity(onAxis ? 0.55 : 0.3))
                            )
                        }
                    }
                    let puck = CGPoint(
                        x: inset + usableW * CGFloat(x + Self.steps) / CGFloat(columns),
                        y: inset + usableH * CGFloat(Self.steps - y) / CGFloat(columns)
                    )
                    for ring in (1...3).reversed() {
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: puck.x - inset - CGFloat(ring) * 2,
                                y: puck.y - inset - CGFloat(ring) * 2 + CGFloat(ring),
                                width: (inset + CGFloat(ring) * 2) * 2,
                                height: (inset + CGFloat(ring) * 2) * 2
                            )),
                            with: .color(.black.opacity(0.16 / Double(ring)))
                        )
                    }
                    context.fill(
                        Path(ellipseIn: CGRect(x: puck.x - inset, y: puck.y - inset, width: inset * 2, height: inset * 2)),
                        with: .color(.accentColor)
                    )
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let inset: CGFloat = 19
                            let usableW = max(geo.size.width - inset * 2, 1)
                            let usableH = max(geo.size.height - inset * 2, 1)
                            let fx = min(max((value.location.x - inset) / usableW, 0), 1)
                            let fy = min(max((value.location.y - inset) / usableH, 0), 1)
                            let nx = Int((fx * Double(Self.steps * 2)).rounded()) - Self.steps
                            let ny = Self.steps - Int((fy * Double(Self.steps * 2)).rounded())
                            if nx != x || ny != y {
                                x = nx
                                y = ny
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                onChange()
                            }
                        }
                )
                .disabled(!enabled)
            }
            .frame(height: Self.padHeight)
            .padding(.horizontal, 20)
            HStack(spacing: 22) {
                Label("Tilt \(Self.signed(x))", systemImage: "waveform")
                Label("Contour \(Self.signed(y))", systemImage: "chart.line.uptrend.xyaxis")
            }
            .font(.body)
            Picker("Width", selection: $focused) {
                Text("Broad").tag(false)
                Text("Focused").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: focused) { _, _ in onChange() }
            Text(focused ? "Narrower shapes around 250 Hz, 1 kHz and 4 kHz." : "Wider shapes with a richer sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

// MARK: - Presets

/// The manual tab's starting points — upstream `EqualizerPreset`, one gain per
/// centre in `EqLayout.MANUAL_BANDS_HZ`. Deliberately modest: every decibel of
/// boost is a decibel of headroom the make-up preamp has to take back.
enum EQPresets {
    struct Preset {
        let name: String
        let gains: [Double]
    }

    static let all: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Acoustic", gains: [3, 1.5, 0, 1.5, 2.5, 2, 1]),
        Preset(name: "Bass Boost", gains: [6, 4, 1.5, 0, 0, 0, 0]),
        Preset(name: "Bass Cut", gains: [-6, -4, -1.5, 0, 0, 0, 0]),
        Preset(name: "Vocal", gains: [-3, -1.5, 1, 3.5, 3, 1, -1]),
        Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 1.5, 3.5, 5]),
        Preset(name: "Treble Cut", gains: [0, 0, 0, 0, -1.5, -3.5, -5]),
        Preset(name: "Loudness", gains: [6, 3.5, 0, -1.5, -1, 2, 5]),
        Preset(name: "Spoken Word", gains: [-5, -2.5, 1.5, 4, 3.5, 1.5, -2]),
        Preset(name: "Electronic", gains: [5, 3, -1, 0, 1, 3, 4]),
        Preset(name: "Rock", gains: [4, 2.5, -1, -1.5, 1, 3, 3.5]),
        Preset(name: "Hip Hop", gains: [6, 4, 0.5, -1, 0.5, 2, 2.5]),
        Preset(name: "Jazz", gains: [3, 1.5, 0, 1, 1.5, 2, 2.5]),
        Preset(name: "Classical", gains: [3, 2, 0, 0, 1, 2.5, 3]),
        Preset(name: "Small Speakers", gains: [5, 4, 2, 0.5, 0, -1, -2]),
        Preset(name: "Late Night", gains: [3, 1, 0, 1.5, 1, -1, -3]),
    ]

    static func matching(_ bands: [Double]) -> String {
        all.first { preset in
            preset.gains.indices.allSatisfy { abs(preset.gains[$0] - bands[$0]) < 0.05 }
        }?.name ?? "Custom"
    }
}

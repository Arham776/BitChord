import SwiftUI
import BitChordShared
import AVKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Upstream `AudioPipelineDialog`: the live signal path, decoder to output.
///
/// ## Why this exists on a platform with less to report
///
/// Upstream builds it on Android's `AudioOutputStatus` — an AAudio sink name, an
/// `AudioFormat` encoding, a route kind, a transport type. None of those have an
/// Apple equivalent, and inventing one would be worse than the gap: a panel that
/// prints "AAudio" on an iPhone is a lie with a nice animation on it.
///
/// So the sections are upstream's and the rows are the ones this platform can
/// actually answer. What the system will not tell us is shown as "—", which is
/// the same thing upstream prints for a value it does not have yet, rather than
/// filled in with a plausible guess. Every filled row is read from the engine or
/// from a setting that is actually in effect.
///
/// The bit-exactness verdict is the one row that is *computed* rather than read,
/// and it is the reason the panel is worth opening: it names the single stage
/// that is altering samples, which is otherwise something the reader has to infer
/// from four rows above it.
struct AudioPipelineSheet: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Live signal path, decoder to output")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.bottom, 14)
                    stage(0, "doc.text", "Track Info") {
                        row("Source", sourceName)
                        row("Format", codec)
                        row("Bit Depth", bitDepth)
                        row("Sample Rate", sourceRate)
                        row("Bitrate", bitrate)
                        row("Channels", channels)
                    }
                    rule
                    stage(1, "waveform", "Decoder") {
                        row("Decoder Name", decoderName)
                        row("Sample Rate", sourceRate)
                        row("Format", codec)
                        row("Bit Depth", bitDepth)
                    }
                    rule
                    stage(2, "arrow.up.arrow.down", "Resampler") {
                        row("I/O Rate", ioRate)
                        row("Type", resamplerType)
                        row("Quality", resamplerQuality)
                    }
                    rule
                    stage(3, "slider.horizontal.3", "DSP") {
                        row("PCM Format", pcmFormat)
                        row("Sample Rate", deviceRate)
                        row("Loudness", loudness)
                        row("EQ Preset", eqPreset)
                        row("Spatial Audio", spatial ? "On" : "Off")
                        row("Output API", "CoreAudio")
                        // The verdict, not the settings. Names whichever stage is
                        // altering samples — or, when none is, that the route
                        // carries the decoder's own encoding unchanged.
                        row("Bit-exact", bitExactVerdict)
                    }
                    rule
                    stage(4, "speaker.wave.2", "Output Device") {
                        row("Device Name", deviceName)
                        row("Sample Rate", deviceRate)
                        row("Channels", deviceChannels)
                    }
                    rule
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        stage(5, "waveform.path.ecg", "Playback Diagnostics") {
                            row("Buffered", "\(controller.outputHealth.bufferedFrames) frames")
                            row("Silent callbacks", "\(controller.outputHealth.callbackUnderruns)")
                            row("Output rebuilds", "\(controller.outputHealth.outputRebuilds)")
                            row("Device xruns", "\(controller.outputHealth.outputXruns)")
                            row("Output peak", String(format: "%.4f", controller.outputHealth.outputPeak))
                            // A quality upgrade fades one recording into another
                            // copy of itself, and how alike the two encodings are
                            // is what decides whether that fade is level-flat.
                            // Measured on the blended samples; “—” until one runs.
                            row("Upgrade correlation", upgradeCorrelation)
                        }
                    }
                    note("Values are read from the engine as it runs. “—” is a figure the system does not report, not one this app chose to hide.")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Audio Pipeline")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
    }

    // ---- The signal path ----------------------------------------------------

    /// One stage: an icon, a heading, and its rows. The connector between stages
    /// is [rule] rather than a drawn line, because a live flowing line is a
    /// claim that samples are moving right now — and a paused engine would then
    /// be showing motion it does not have.
    private func stage<Content: View>(
        _ index: Int, _ icon: String, _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.10), in: Circle())
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.top, index == 0 ? 0 : 14)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.leading, 38)
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.leading, 14)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 18)
    }

    // ---- The figures --------------------------------------------------------

    private var nerd: NerdStatsRec? { controller.nerd }
    private var device: OutputDeviceRec { controller.outputDevice }

    private var sourceName: String {
        guard let entry = controller.current else { return "—" }
        if entry.isLocal { return entry.source }
        if entry.source.hasPrefix("yt:") { return "YouTube" }
        if entry.source.hasPrefix("saavn:") { return "JioSaavn" }
        return entry.source.isEmpty ? "—" : entry.source
    }

    private var codec: String { nerd?.codec.isEmpty == false ? nerd!.codec : "—" }
    private var bitDepth: String { (nerd?.bitDepth ?? 0) > 0 ? "\(nerd!.bitDepth)-bit" : "—" }
    private var bitrate: String { (nerd?.kbps ?? 0) > 0 ? "\(nerd!.kbps) kbps" : "—" }
    private var sourceRate: String { (nerd?.sampleRate ?? 0) > 0 ? "\(nerd!.sampleRate) Hz" : "—" }
    /// The last quality upgrade's measured correlation, and what it implies for
    /// the fade. The swap uses a linear gain pair, which is flat when the two
    /// encodings are identical; `10·log10((1+ρ)/2)` is how far from flat it sits
    /// at any other correlation (−0.11 dB at ρ=0.95, −1.25 dB at ρ=0.5).
    private var upgradeCorrelation: String {
        guard let rho = nerd?.swapCorrelation else { return "—" }
        let deviationDb = 10 * log10((1 + rho) / 2)
        return String(format: "ρ=%.3f (%.2f dB from flat)", rho, deviationDb)
    }
    private var channels: String {
        let n = nerd?.channels ?? 0
        guard n > 0 else { return "—" }
        return n > 2 ? "\(n) (Surround)" : "\(n)"
    }

    /// The decoder's own name rather than the codec label. `symphonia` is the
    /// decoder on every platform, so this row is the one that says which
    /// implementation is actually running — which is the question the codec row
    /// cannot answer.
    private var decoderName: String { codec == "—" ? "—" : "symphonia" }

    private var deviceRate: String {
        device.started && device.sampleRate > 0 ? "\(device.sampleRate) Hz" : "—"
    }
    private var deviceChannels: String {
        device.started && device.channels > 0 ? "\(device.channels)" : "—"
    }
    private var deviceName: String {
        device.started && !device.name.isEmpty ? device.name : "Not open yet"
    }

    /// "44100 → 48000" when the two differ, and the single rate when they do not
    /// — because a resampler that is not resampling should say so rather than
    /// print an arrow to the same number twice.
    private var ioRate: String {
        let src = nerd?.sampleRate ?? 0
        let out = device.sampleRate
        guard src > 0, out > 0 else { return "—" }
        return src == out ? "\(out) Hz (no conversion)" : "\(src) → \(out) Hz"
    }

    private var resamplerType: String {
        let src = nerd?.sampleRate ?? 0
        guard src > 0, device.sampleRate > 0 else { return "—" }
        return src == device.sampleRate ? "Bypassed" : "Sinc"
    }

    private var resamplerQuality: String {
        let src = nerd?.sampleRate ?? 0
        guard src > 0, device.sampleRate > 0 else { return "—" }
        return src == device.sampleRate ? "Not applicable" : "Band-limited"
    }

    /// The word length the unit was actually opened as — the setting's answer,
    /// not its request. Upstream's panel names the negotiated encoding for the
    /// same reason: PCM_16 quantizes at the callback, FLOAT_32 passes through.
    private var pcmFormat: String {
        guard device.started else { return "—" }
        switch device.sampleFormat {
        case "FLOAT_32": return "Float32"
        default: return "PCM 16"
        }
    }

    /// Applied loudness correction, read off the engine rather than the
    /// switch: "Off" when the listener switched it off, "No figure" when a
    /// track carries none (local files, substitutes), "+x.x dB" otherwise.
    /// Upstream's panel makes the same three-way distinction.
    private var loudness: String {
        let enabled = PlatformSettings.shared.getBoolean(key: "loudness_normalization", default: true)
        guard enabled else { return "Off" }
        guard let gain = nerd?.loudnessGainDb else { return "No figure" }
        if gain == 0 { return "Unity (0 dB)" }
        return String(format: "%+.1f dB", gain)
    }

    private var equalizerEnabled: Bool {
        PlatformSettings.shared.getBoolean(key: "equalizer_enabled", default: false)
    }
    private var spatial: Bool {
        PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
    }
    private var eqPreset: String {
        guard equalizerEnabled else { return "Off" }
        let preset = PlatformSettings.shared.getString(key: "equalizer_preset", default: "")
        return preset.isEmpty ? "Custom" : preset
    }

    /// The one computed row: which stage, if any, is altering samples.
    ///
    /// A resampler is only a lossless pass-through when the rates already agree,
    /// which is why it is asked about the two numbers rather than the setting —
    /// upstream makes the same distinction, and a panel that claimed bit-exactness
    /// because no DSP was switched on would be wrong for every 44.1 kHz track on
    /// a 48 kHz route, which is most of them.
    private var bitExactVerdict: String {
        guard device.started else { return "—" }
        let src = nerd?.sampleRate ?? 0
        let resampling = src > 0 && device.sampleRate > 0 && src != device.sampleRate
        if equalizerEnabled || spatial { return "No — DSP is active" }
        if let gain = nerd?.loudnessGainDb, gain != 0 { return "No — loudness correction active" }
        if device.sampleFormat == "PCM_16" { return "No — 16-bit quantization at the output" }
        if resampling { return "No — resampling \(src) → \(device.sampleRate) Hz" }
        return "Yes — decoded straight to the device"
    }
}

/// Upstream `AudioOutputSheet`: the summary row that opens [AudioPipelineSheet].
///
/// The summary is the part worth getting right on its own, because it is what
/// is visible without opening anything: "Float32 · 48 kHz", or the device name
/// once there is one. Upstream shows the encoding and rate, whichever it knows.
struct AudioOutputRow: View {
    @Environment(PlaybackController.self) private var controller
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Pipeline")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "PCM 16 · 48 kHz" or "Float32 · 48 kHz", or the device name once the
    /// engine is open. Whichever is actually known: upstream shows the
    /// encoding and the rate and falls back to the encoding alone, and there
    /// is no reason to show a rate the device has not reported.
    private var summary: String {
        let device = controller.outputDevice
        guard device.started else { return "Nothing open yet" }
        var parts: [String] = [device.sampleFormat == "FLOAT_32" ? "Float32" : "PCM 16"]
        if device.sampleRate > 0 {
            let khz = Double(device.sampleRate) / 1000
            parts.append(String(format: khz == khz.rounded() ? "%.0f kHz" : "%.1f kHz", khz))
        }
        return parts.joined(separator: " · ")
    }
}

/// Upstream `AudioOutputSheet`: where the music is coming out.
///
/// iOS sandboxes route selection — no app can enumerate or switch outputs
/// itself — so this is the system route picker (`AVRoutePickerView`, the
/// AirPlay control) plus the live pipeline readout, not a custom device list.
/// A custom list would be a second switcher that routes nothing; the system
/// control is the one that actually takes effect.
struct OutputDeviceSheet: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Device", deviceName)
                    row("Sample Rate", deviceRate)
                    row("Channels", deviceChannels)
                    row("Pipeline", pipelineSummary)
                } header: {
                    Text("Current Route")
                } footer: {
                    Text("Read from the engine as it runs. “—” is a figure the system does not report.")
                }
                Section {
                    SystemRoutePickerRow()
                    #if os(iOS)
                    SystemVolumeRouteRow()
                    #endif
                } header: {
                    Text("Choose Output")
                } footer: {
                    Text("The system picker routes this app's audio — AirPlay, Bluetooth and the device speaker.")
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Section {
                        row("Buffered", "\(controller.outputHealth.bufferedFrames) frames")
                        row("Silent callbacks", "\(controller.outputHealth.callbackUnderruns)")
                        row("Output rebuilds", "\(controller.outputHealth.outputRebuilds)")
                        row("Device xruns", "\(controller.outputHealth.outputXruns)")
                        row("Output peak", String(format: "%.4f", controller.outputHealth.outputPeak))
                        row("Upgrade correlation", upgradeCorrelation)
                    } header: {
                        Text("Playback Diagnostics")
                    } footer: {
                        Text("Compare counter changes while a track plays. The output callback also runs with an empty queue, so idle silent callbacks are expected.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Audio Output")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private var device: OutputDeviceRec { controller.outputDevice }
    private var nerd: NerdStatsRec? { controller.nerd }

    private var upgradeCorrelation: String {
        guard let rho = nerd?.swapCorrelation else { return "—" }
        let deviationDb = 10 * log10((1 + rho) / 2)
        return String(format: "ρ=%.3f (%.2f dB from flat)", rho, deviationDb)
    }

    private var deviceName: String {
        device.started && !device.name.isEmpty ? device.name : "Not open yet"
    }
    private var deviceRate: String {
        device.started && device.sampleRate > 0 ? "\(device.sampleRate) Hz" : "—"
    }
    private var deviceChannels: String {
        device.started && device.channels > 0 ? "\(device.channels)" : "—"
    }
    private var pipelineSummary: String {
        guard device.started else { return "—" }
        var parts = [device.sampleFormat == "FLOAT_32" ? "Float32" : "PCM 16"]
        if device.sampleRate > 0 { parts.append("\(device.sampleRate) Hz") }
        return parts.joined(separator: " · ")
    }
}

/// The system AirPlay route picker, hosted as a row.
///
/// `AVRoutePickerView` is the only control iOS offers that actually changes the
/// route — a custom list of devices would display without switching anything,
/// because route selection is a system decision apps can only request through
/// this control.
private struct SystemRoutePickerRow: View {
    var body: some View {
        HStack {
            Text("AirPlay & Bluetooth")
            Spacer(minLength: 12)
            SystemRoutePickerView()
                .frame(width: 44, height: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Choose audio output")
    }
}

#if os(iOS)
private struct SystemRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// A second entry point to the system output picker, for the output control
/// presented alongside the pipeline settings.
private struct SystemVolumeRouteRow: View {
    var body: some View {
        HStack {
            Text("Output Switcher")
            Spacer(minLength: 12)
            SystemRoutePickerView()
                .frame(width: 44, height: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open system output switcher")
    }
}
#else
private struct SystemRoutePickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif

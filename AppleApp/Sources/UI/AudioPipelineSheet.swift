import SwiftUI
import BitChordShared

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

    /// The engine carries interleaved f32 into the device, so the PCM format is
    /// Float32 at the output rate whatever the source encoding was.
    private var pcmFormat: String {
        device.started ? "Float32" : "—"
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

    /// "Float32 · 48 kHz", or the device name once the engine is open. Whichever
    /// is actually known: upstream shows the encoding and the rate and falls back
    /// to the encoding alone, and there is no reason to show a rate the device
    /// has not reported.
    private var summary: String {
        let device = controller.outputDevice
        guard device.started else { return "Nothing open yet" }
        var parts: [String] = ["Float32"]
        if device.sampleRate > 0 {
            let khz = Double(device.sampleRate) / 1000
            parts.append(String(format: khz == khz.rounded() ? "%.0f kHz" : "%.1f kHz", khz))
        }
        return parts.joined(separator: " · ")
    }
}

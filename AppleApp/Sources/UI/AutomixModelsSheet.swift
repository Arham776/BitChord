import SwiftUI
import BitChordShared

/// Whether an Automix model download may use the connection in hand.
///
/// The same question the download screen asks about songs, asked the same way and
/// answered by the same setting — a listener who has told BitChord not to spend
/// mobile data on downloads has told it about this download too, and a second
/// switch for the same preference is a second thing to get wrong.
@MainActor
enum AutomixModelsPolicy {
    static var isMetered: Bool { NetworkQuality.shared.metered }

    static var wifiOnly: Bool {
        PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
    }

    /// True when the transfer may start right now.
    static var allowMetered: Bool { !(isMetered && wifiOnly) }
}

/// One model, its state, and the action that state calls for.
///
/// Shared by the first-run sheet and the Settings page so the two cannot drift:
/// the rules about what "installed" means and what a tap does live in one place,
/// and the two screens differ only in how much room they give it.
struct AutomixModelRow: View {
    let id: AutomixModelStore.ModelID
    let store: AutomixModelStore

    var body: some View {
        let spec = store.spec(id)
        let status = store.status(of: id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(spec.displayName)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(spec.sizeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(spec.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls(spec: spec, status: status)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func controls(spec: AutomixModelStore.ModelSpec, status: AutomixModelStore.Status) -> some View {
        switch status {
        case .notInstalled:
            action("Download") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }

        case .paused(let bytes):
            HStack(spacing: 10) {
                Text("Paused at \(AutomixModelStore.bytes(bytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                action("Resume") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }
                Button("Discard") { store.remove(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancel(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
            }

        case .verifying:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking the download…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .installed:
            HStack(spacing: 12) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                Button("Verify") { store.verify(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                Button("Remove") { store.remove(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }

        case .blockedByWifi:
            HStack(spacing: 10) {
                Text("Waiting for Wi‑Fi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                action("Download anyway") { store.start(id, allowMetered: true) }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                action("Try again") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }
            }
        }
    }

    @ViewBuilder
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// The first-run offer.
///
/// A sheet rather than a download that starts on its own: 123 MB is not a thing to
/// spend on somebody's behalf without asking, and the question is also the only
/// place the *reason* fits — a listener who has not turned Automix on yet has no
/// way to know what a beat grid is for. Declining is remembered, and the offer
/// stays reachable in Settings for anyone who changes their mind.
struct AutomixModelsSheet: View {
    /// Called when the listener declines, so the app can remember it.
    var onDecline: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// Optional because this sheet is presented from two places and only one of them
    /// has a toast host above it: on macOS the Settings screen is its own window, and
    /// a required environment value that is missing is a crash, not a missing notice.
    /// The rows carry the state either way.
    @Environment(ToastCenter.self) private var toast: ToastCenter?

    private let store = AutomixModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install Automix models?")
                    .font(.title3.weight(.semibold))
                Text("Automix times each transition from the music itself. That needs two analysis models, which are downloaded once and kept on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AutomixModelRow(id: .beat, store: store)
                    Divider()
                    AutomixModelRow(id: .vocals, store: store)
                    Text("Beat and downbeat detection is what makes a transition land on the music; vocal detection is what stops two vocals being blended over each other. Either can be added or removed later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("From Hugging Face, MIT-licensed. Checksummed after download.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Not now") {
                    onDecline()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Download") {
                    store.start(.beat, allowMetered: AutomixModelsPolicy.allowMetered)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.status(of: .beat).isInstalled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 480, minHeight: 460)
        .task { store.refresh() }
        .onChange(of: store.status) { old, new in
            announce(from: old, to: new)
        }
    }

    /// Only transitions are announced. `status` is a dictionary that changes for
    /// every progress tick, so a notice per change would be a notice per percent.
    private func announce(
        from old: [AutomixModelStore.ModelID: AutomixModelStore.Status],
        to new: [AutomixModelStore.ModelID: AutomixModelStore.Status]
    ) {
        for id in AutomixModelStore.ModelID.allCases {
            let spec = store.spec(id)
            let was = old[id] ?? .notInstalled
            let now = new[id] ?? .notInstalled
            guard was != now else { continue }
            switch now {
            case .installed:
                toast?.show("\(spec.displayName) installed")
            case .failed(let message):
                toast?.show(message, kind: .failure)
            default:
                break
            }
        }
    }
}

/// The same rows in Settings, for anyone who declined or wants to change the set.
struct AutomixModelsPage: View {
    private let store = AutomixModelStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(AutomixModelStore.ModelID.allCases) { id in
                    AutomixModelRow(id: id, store: store)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Downloaded once and kept in BitChord's own storage. Removing a model takes effect immediately: Automix falls back to tempo analysis without the beat model, and stops watching for vocal clashes without the vocal one.")
            }
            Section {
                if store.totalBytesOnDisk > 0 {
                    LabeledContent("On disk", value: AutomixModelStore.bytes(store.totalBytesOnDisk))
                }
                LabeledContent("Source", value: "Hugging Face")
                LabeledContent("Licence", value: "MIT")
            } footer: {
                Text("Beat This! (beat and downbeat detection) and open-unmix UMX-L (vocal detection). Both are verified against a pinned checksum after download.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automix Models")
        .task { store.refresh() }
    }
}

import SwiftUI
import BitChordShared

/// Settings. On iOS this is a sheet from the toolbar gear. On macOS it is the
/// standard Settings window (`BitChord → Settings…`, ⌘,) — not a gear in the
/// main window toolbar.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @State private var crossfade: Int32 = PlatformSettings.shared.getInt(key: "crossfade_seconds", default: 0)
    @State private var spatial = PlatformSettings.shared.getBoolean(key: "spatial_audio", default: false)
    @State private var autoplay = PlatformSettings.shared.getBoolean(key: "autoplay", default: true)
    @State private var loginPresented = false

    var body: some View {
        #if os(macOS)
        form
            .formStyle(.grouped)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
            .sheet(isPresented: $loginPresented) { loginSheet }
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: save)
                    }
                }
        }
        .sheet(isPresented: $loginPresented) { loginSheet }
        #endif
    }

    private var form: some View {
        Form {
            Section("YouTube Music") {
                if auth.signedIn {
                    LabeledContent("Account", value: auth.accountName ?? "Signed in")
                    if let email = auth.accountEmail, !email.isEmpty {
                        LabeledContent("Signed in as", value: email)
                    }
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In") {
                        loginPresented = true
                    }
                }
                Text("Sign-in uses Google's own login page. BitChord stores only the session cookie in the Keychain and never your password. Playback still uses unsigned device clients — the session is not sent to googlevideo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Playback") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Crossfade")
                        Spacer()
                        Text(crossfade == 0 ? "Off" : "\(crossfade)s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(crossfade) },
                        set: { crossfade = Int32($0.rounded()) }
                    ), in: 0...12, step: 1)
                    Text("Gapless stays on regardless; the crossfade blends two tracks at the boundary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                Toggle("Spatial widening", isOn: $spatial)
                Text("Widens the stereo image the way upstream does — not Dolby Atmos. Headphones show it most clearly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Autoplay", isOn: $autoplay)
            }
            Section("About") {
                LabeledContent("Engine", value: "native-core v\(coreVersion())")
                LabeledContent("Logic core", value: GreetingKt.sharedGreeting())
            }
        }
        .onChange(of: spatial) { _, value in
            AppSettings.shared.setSpatialAudio(value: value)
            controller.updateSpatial(enabled: value)
        }
        .onChange(of: crossfade) { _, value in
            AppSettings.shared.setCrossfadeSeconds(value: value)
            controller.updateCrossfade(seconds: Int(value))
        }
        .onChange(of: autoplay) { _, value in
            AppSettings.shared.setAutoplay(value: value)
        }
    }

    private var loginSheet: some View {
        NavigationStack {
            YtMusicLoginView { header in
                auth.accept(header)
                loginPresented = false
            }
            .navigationTitle("Sign in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { loginPresented = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }

    private func save() {
        AppSettings.shared.setCrossfadeSeconds(value: crossfade)
        AppSettings.shared.setSpatialAudio(value: spatial)
        AppSettings.shared.setAutoplay(value: autoplay)
        controller.updateCrossfade(seconds: Int(crossfade))
        controller.updateSpatial(enabled: spatial)
        dismiss()
    }
}

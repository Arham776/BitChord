import SwiftUI
import BitChordShared

@main
struct BitChordApp: App {
    @State private var controller = PlaybackController()
    @State private var appModel = AppModel()
    @State private var auth = AuthController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .task {
                    CipherUnlockWiring.install()
                    auth.restore()
                    controller.startEngineIfNeeded()
                    LocalLibrary.shared.restore()
                }
                .onChange(of: scenePhase) { _, phase in
                    appModel.scenePhase = phase
                }
                .onOpenURL { url in
                    // External link intake (spec §1.3): the parser lives in
                    // `shared` (MusicLink); the seam is here. v1 routes the
                    // widget's player deep link; full link resolution lands
                    // with the browse milestones.
                    if url.absoluteString.contains("open-player") {
                        appModel.nowPlayingPresented = true
                    }
                    _ = MusicLink.shared.submitUrl(url: url.absoluteString)
                }
        }
#if os(macOS)
        .windowStyle(.automatic)
#endif
#if os(macOS)
        Settings {
            SettingsView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
        }
#endif
    }
}

/// App-level state that is not playback: navigation triggers, external-link
/// intake, tab persistence.
@Observable
final class AppModel {
    var scenePhase: ScenePhase = .active
    var nowPlayingPresented = false
    /// Cross-tab navigation request — RootView observes and consumes it.
    var requestedTab: Tab?

    /// The four canonical tabs (UI spec §2).
    enum Tab: Int, Hashable {
        case home, explore, library, search
    }
}

import SwiftUI
import BitChordShared

@main
struct BitChordApp: App {
    @State private var controller = PlaybackController()
    @State private var appModel = AppModel()
    @State private var auth = AuthController()
    @State private var toast = ToastCenter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .task {
                    CipherUnlockWiring.install()
                    SecretStoreWiring.install()
                    installAutomixModels()
                    controller.startEngineIfNeeded()
                    LocalLibrary.shared.restore()
                    DownloadStore.shared.refresh()
                    Task { await StreamFileCache.shared.trim() }
                    let token = PlatformSettings.shared.getString(key: "discord_token", default: "")
                    if !token.isEmpty { DiscordGateway.shared.connect(token: token) }
                }
                .onChange(of: scenePhase) { _, phase in
                    appModel.scenePhase = phase
                    if phase == .background {
                        controller.persistSession()
                        if PlatformSettings.shared.getBoolean(key: "stop_when_backgrounded", default: false) {
                            controller.pauseForBackground()
                        }
                    }
                }
                .onOpenURL { url in
                    // Handling lives here, on the scene, rather than on `RootView`.
                    // It was installed in both places, so whichever ran second
                    // consumed the link and the other was dead — a `bitchord://`
                    // link reached the player only by accident of ordering. On the
                    // scene it runs before the view hierarchy exists, which is what
                    // a cold launch from a link actually needs.
                    if url.absoluteString.contains("open-player") {
                        appModel.nowPlayingPresented = true
                    }
                    _ = MusicLink.shared.submitUrl(url: url.absoluteString)
                    consumeMusicLink(appModel: appModel, controller: controller)
                }
        }
#if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.automatic)
        .commands { PlaybackCommands(controller: controller, appModel: appModel) }
#endif
#if os(macOS)
        Settings {
            SettingsView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .preferredColorScheme(appModel.preferredScheme)
                .environment(\.locale, appModel.appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appModel.appLanguage))
        }
        #endif
    }
}

private func installAutomixModels() {
    let beat = Bundle.main.url(forResource: "beat_this", withExtension: "onnx", subdirectory: "Models")
        ?? Bundle.main.url(forResource: "beat_this", withExtension: "onnx")
    let vocal = Bundle.main.url(forResource: "vocals_umxhq", withExtension: "onnx", subdirectory: "Models")
        ?? Bundle.main.url(forResource: "vocals_umxhq", withExtension: "onnx")
    _ = configureAnalyzer(
        beatModelPath: beat?.path ?? "",
        vocalModelPath: vocal?.path ?? ""
    )
}

/// App-level state that is not playback: navigation triggers, external-link
/// intake, tab persistence.
@Observable
final class AppModel {
    var scenePhase: ScenePhase = .active
    var nowPlayingPresented = false
    /// Cross-tab navigation request — RootView observes and consumes it.
    var requestedTab: Tab?
    var pendingDetail: BrowseDestination?
    var playlistPicker: PlaylistPickerRequest?
    var downloadManagerPresented = false
    var replayPresented = false
    var focusSearch = false
    var pendingSearchQuery: String?
    /// Set by the macOS menu commands to ask the player to reveal a pane that is
    /// otherwise behind a toggle. One-shot: the player consumes it and clears it,
    /// so holding ⌘U does not keep re-toggling.
    var queueRevealRequested = false
    var lyricsRevealRequested = false
    var themeMode = PlatformSettings.shared.getString(key: "theme_mode", default: "dark")
    var appLanguage = PlatformSettings.shared.getString(key: "app_language", default: "")
    var pinLimitAlert = false
    var playlistRename: PlaylistRenameRequest?

    var preferredScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Canonical tabs (UI spec §2). macOS Library sub-destinations live as
    /// extra cases so they can group under a `TabSection` in the sidebar.
    enum Tab: Int, Hashable {
        case home, explore, library, search
        case libraryYouTube, librarySongs, libraryAlbums
        case libraryArtists, libraryDownloads, libraryHistory
    }
}

@MainActor
func consumeMusicLink(appModel: AppModel, controller: PlaybackController) {
    guard let json = MusicLink.shared.takePendingJson(),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = obj["kind"] as? String else { return }
    switch kind {
    case "track":
        if let id = obj["id"] as? String {
            controller.play([
                QueueEntry.youtube(videoId: id, title: "Loading…", artist: "", thumbnailUrl: nil)
            ], at: 0)
        }
    case "page":
        if let id = obj["id"] as? String {
            appModel.pendingDetail = .detail(browseId: id, title: "")
        }
    case "search":
        if let query = obj["query"] as? String {
            appModel.pendingSearchQuery = query
            appModel.requestedTab = .search
            appModel.focusSearch = true
            if obj["play"] as? Bool == true {
                Task {
                    if let hit = try? await InnertubeSearch.shared.search(query, scope: "songs").first(where: { !$0.isBrowse }) {
                        controller.play([hit.asEntry()], at: 0)
                    }
                }
            }
        }
    case "resume":
        if !controller.isPlaying { controller.togglePlayPause() }
    default:
        break
    }
}

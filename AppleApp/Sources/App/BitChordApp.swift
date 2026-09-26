import SwiftUI
import BitChordShared

@main
struct BitChordApp: App {
    @State private var controller = PlaybackController()
    @State private var appModel = AppModel()
    @State private var auth = AuthController()
    @State private var toast = ToastCenter()
    @State private var party = PartyStore.shared
    /// The one binding between a party and this device's player.
    ///
    /// Replaced rather than constructed inline, because it has to hold *this* session's
    /// `PlaybackController` and a `@State` initialiser runs before the environment is
    /// available. Kept at the app rather than in a view because a party's lifetime is
    /// the listener's and not a view's — most of listening together is the screen
    /// being somewhere else.
    @State private var partySync = PartySync(controller: PlaybackController())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .environment(toast)
                .environment(party)
                .task {
                    CipherUnlockWiring.install()
                    SecretStoreWiring.install()
                    ModuleEngineWiring.install()
                    PartySocket.register()
                    // Before anything can reach the coordinator: it needs the platform
                    // clock and somewhere to publish, and a coordinator that has
                    // neither measures against a clock of zero and believes the answer.
                    PartyStore.install()
                    partySync = PartySync(controller: controller)
                    party.attach(player: partySync)
                    // The player tells the party when the *listener* presses something,
                    // so a press is not undone by the next frame still describing the
                    // old transport. Wired here, once, because the controller outlives
                    // every view and the party binding is replaced on each launch.
                    controller.onLocalIntent = { [weak partySync] in
                        partySync?.onLocalIntent()
                    }
                    installAutomixModels()
                    controller.startEngineIfNeeded()
                    LocalLibrary.shared.restore()
                    DownloadStore.shared.refresh()
                    Task { await StreamFileCache.shared.trim() }
                    let token = PlatformSettings.shared.getSecret(key: "discord_token") ?? ""
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
                    // An invite is not joined on the spot: it is carried to the
                    // Listen Together screen, which shows who is in the party before
                    // a slot is committed. Same as upstream, where a link is consent
                    // to *look*, not to join. The screen carries its own server editor,
                    // so a link pointing at somebody else's server needs no trip
                    // through Settings to get there.
                    if JamInviteLink.shared.looksLikeInvite(value: url.absoluteString) {
                        appModel.pendingPartyInvite = url.absoluteString
                        appModel.listenTogetherPresented = true
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
    /// Bumped when the already-selected Search tab is tapped again, so the field
    /// can take focus. Upstream's `searchFocusTrigger`.
    ///
    /// A counter rather than a flag: a flag has to be cleared by whoever reads
    /// it, and two taps in quick succession would otherwise be one tap's worth of
    /// intent. Counting means the second tap is honoured even if the first is
    /// still being handled.
    var searchFocusTrigger = 0
    var pendingDetail: BrowseDestination?
    var playlistPicker: PlaylistPickerRequest?
    var downloadManagerPresented = false
    var replayPresented = false
    /// Listen Together, presented over whatever the listener was doing.
    ///
    /// Its own flag rather than a settings row, because a party invite is a request
    /// to *look* at a party, and the screen that answers it has to be the one that
    /// arrives — making somebody find Settings first would put a settings window
    /// between a link and the thing the link is about.
    var listenTogetherPresented = false
    /// Who is listening, from inside the player.
    ///
    /// Its own flag rather than a sheet hung off the playback pill, because the pill
    /// is built twice — once per platform — and two sheets on it means two sheets
    /// fighting over the same presentation.
    var partyMembersPresented = false
    /// An invite link that arrived from outside, waiting to be looked at.
    var pendingPartyInvite: String?
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
        case libraryArtists, libraryDownloads, libraryHistory, libraryWebDav
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

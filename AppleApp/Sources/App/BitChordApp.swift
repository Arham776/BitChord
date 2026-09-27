import SwiftUI
import Observation
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
                    let localPartySync = partySync
                    controller.onLocalIntent = { [weak localPartySync] in
                        localPartySync?.onLocalIntent()
                    }
                    // What is on disk decides what the analyzer gets. Refreshed first
                    // so a resumed or already-downloaded graph is visible, and loaded
                    // in the background: 123 MB of ONNX is seconds of work and the
                    // engine should not wait behind it. Whatever is missing stays
                    // missing, and Automix keeps its tempo fallback — the whole reason
                    // the models are optional.
                    AutomixModelStore.shared.refresh()
                    AutomixModelStore.shared.onChanged = {
                        Task { await reloadAutomixModels() }
                    }
                    Task { await reloadAutomixModels() }
                    // Engine is started on-demand when the user actually begins
                    // playback (via playQueue, togglePlayPause, or remote commands)
                    // so opening the app never interrupts other audio playing on the device.
                    // After the shell is up and the first frame has been drawn: an
                    // offer as the window appears reads as chrome, and one that
                    // arrives a moment later reads as a question.
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        appModel.offerAutomixModelsIfNeeded()
                    }
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
                    } else if phase == .active {
                        controller.reactivateAudioSessionAfterForeground()
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
                        let requestedScreen = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "screen" })?.value
                        if requestedScreen?.caseInsensitiveCompare("lyrics") == .orderedSame {
                            PlatformSettings.shared.putString(key: "last_player_screen", value: "LYRICS")
                        }
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

/// Hand the analyzer whatever Automix graphs this device has.
///
/// The paths are resolved on the main actor — the store's state and the bundle
/// live there — and the load itself runs detached. `configureAnalyzer` accepts
/// empty paths and treats them as "unload", which is what a model that was removed,
/// or never downloaded, must mean: Automix falls back to the tempo planner and
/// stops avoiding vocal clashes rather than refusing to transition at all.
///
/// Called once at launch and again after every install or removal, so a model that
/// arrives mid-session is in use without a relaunch.
@MainActor
private func reloadAutomixModels() async {
    let paths = AutomixModelStore.shared.analyzerPaths
    let ready = await Task.detached(priority: .userInitiated) {
        configureAnalyzer(beatModelPath: paths.beat, vocalModelPath: paths.vocal)
    }.value
    DebugLog.shared.d(
        message: "automix models: beat=\(paths.beat) vocal=\(paths.vocal) loaded=\(ready)"
    )
}

/// App-level state that is not playback: navigation triggers, external-link
/// intake, tab persistence.
@Observable
final class AppModel {
    var scenePhase: ScenePhase = .active
    var nowPlayingPresented = false
    /// Presented by the account control in each iPhone tab's own toolbar.
    var settingsPresented = false
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
    /// Which Replay story to open when the sheet arrives. Set alongside
    /// `replayPresented` by library heroes — a tapped card opens Replay at
    /// its chart, the empty-state banner at the intro — and consumed by
    /// `ReplayView` on appear. Nil means the main Replay page.
    var replayInitialPage: ReplayStoryPage?
    /// Open Replay, optionally at one story page. Upstream's `onOpenReplay`.
    func openReplay(at page: ReplayStoryPage? = nil) {
        replayInitialPage = page
        replayPresented = true
    }
    /// The first-run Automix models offer. Set by ``offerAutomixModelsIfNeeded()``
    /// and consumed by `RootView`.
    var automixModelsPresented = false
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

    /// Whether the first-run offer has already been made this launch.
    ///
    /// Session-scoped rather than persisted: the persisted flag is the listener's
    /// "no", and it means "stop bringing this up on your own", not "never mention
    /// it again". Turning Automix on is a fresh question, and answering it with
    /// silence would leave the feature quietly half-working.
    @ObservationIgnored private var automixModelsAskedThisLaunch = false

    /// Offer the models, when there is something to offer and nobody has said no.
    ///
    /// The beat model is the line: with it installed the offer has nothing to add,
    /// and without it Automix is running on the tempo fallback whether or not the
    /// listener knows.
    @MainActor
    func offerAutomixModelsIfNeeded() {
        guard !AutomixModelStore.shared.beatInstalled else { return }
        guard !automixModelsPresented else { return }
        guard !automixModelsAskedThisLaunch else { return }
        // The session flag is spent only when the offer is actually shown. A launch
        // that honours a previous "not now" has not asked the listener anything, so
        // switching Automix on later in that session is still free to.
        guard !PlatformSettings.shared.getBoolean(key: "automix_models_prompt_dismissed", default: false) else { return }
        automixModelsAskedThisLaunch = true
        automixModelsPresented = true
    }

    /// Whether switching Automix on may put the offer up again, once per launch.
    ///
    /// Separate from ``offerAutomixModelsIfNeeded()`` because the two present from
    /// different places — the root sheet and the Settings window — and a decline is
    /// about the launch offer, not about the deliberate act of turning the feature
    /// on and being told nothing.
    @MainActor
    func mayAskForAutomixModels() -> Bool {
        guard !AutomixModelStore.shared.beatInstalled else { return false }
        guard !automixModelsAskedThisLaunch else { return false }
        automixModelsAskedThisLaunch = true
        return true
    }

    /// Remember a "not now", so the launch offer does not return on its own.
    func declineAutomixModels() {
        PlatformSettings.shared.putBoolean(key: "automix_models_prompt_dismissed", value: true)
    }

    /// Canonical tabs (UI spec §2). macOS Library sub-destinations live as
    /// extra cases so they can group under a `TabSection` in the sidebar.
    enum Tab: Int, Hashable {
        case home, explore, library, search
        case libraryYouTube, librarySongs, libraryAlbums
        case libraryArtists, libraryDownloads, libraryHistory, libraryWebDav
        case libraryPlaylists, librarySubscriptions, libraryPodcasts, libraryOnDevice
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

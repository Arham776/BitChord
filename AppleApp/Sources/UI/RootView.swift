import SwiftUI
import BitChordShared
#if os(iOS)
import UIKit
#endif

/// Root navigation shell — one `TabView` with `.sidebarAdaptable` (UI spec §2):
/// bottom tab bar on iOS, Apple Music's leading sidebar on macOS, from a
/// single declaration. Exactly four canonical tabs, upstream icons, search
/// role pinned trailing. `@SceneStorage` keeps the last tab across launches.
struct RootView: View {
    @SceneStorage("bitchord.selectedTab") private var selection: Int = AppModel.Tab.home.rawValue
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth
    @Environment(ToastCenter.self) private var toast
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var homeFeed = FeedLoader(.home)
    #if os(iOS)
    @Namespace private var nowPlayingZoom
    #endif

    var body: some View {
        shell
        .onChange(of: appModel.requestedTab) { _, requested in
            guard let requested else { return }
            selection = resolvedTab(requested).rawValue
            appModel.requestedTab = nil
        }
        .sheet(isPresented: Binding(
            get: { auth.loginPresented },
            set: { auth.loginPresented = $0 }
        )) {
            NavigationStack {
                YtMusicLoginView(
                    onCaptured: { session, done in
                        auth.accept(session) { accepted in
                            if accepted { auth.loginPresented = false }
                            done(accepted)
                        }
                    },
                    onDismiss: { auth.loginPresented = false }
                )
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 640)
            #endif
        }
        .sheet(item: Binding(
            get: { appModel.playlistPicker },
            set: { appModel.playlistPicker = $0 }
        )) { req in
            PlaylistPickerView(request: req)
        }
        .sheet(isPresented: Binding(
            get: { appModel.downloadManagerPresented },
            set: { appModel.downloadManagerPresented = $0 }
        )) {
            DownloadManagerView()
        }
        .sheet(isPresented: Binding(
            get: { appModel.replayPresented },
            set: { appModel.replayPresented = $0 }
        )) {
            ReplayView()
        }
        // Listen Together, presented over whatever the listener was doing. A party
        // invite is a request to look at a party, and the screen that answers it has
        // to be the one that arrives.
        .sheet(isPresented: Binding(
            get: { appModel.listenTogetherPresented },
            set: { appModel.listenTogetherPresented = $0 }
        )) {
            NavigationStack { ListenTogetherView() }
        }
        .sheet(isPresented: Binding(
            get: { appModel.partyMembersPresented },
            set: { appModel.partyMembersPresented = $0 }
        )) {
            PartyMembersSheet()
                .environment(PartyStore.shared)
        }
        // The first-run model offer. Its own sheet at the root, because it is the
        // one question the app asks before it has been used at all and it must not
        // be attached to a screen the listener might never open.
        .sheet(isPresented: Binding(
            get: { appModel.automixModelsPresented },
            set: { appModel.automixModelsPresented = $0 }
        )) {
            AutomixModelsSheet(onDecline: { appModel.declineAutomixModels() })
        }
        .sheet(item: Binding(
            get: { appModel.pendingDetail },
            set: { appModel.pendingDetail = $0 }
        )) { dest in
            NavigationStack {
                if case .detail(let id, let title) = dest {
                    DetailView(browseId: id, initialTitle: title)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { appModel.pendingDetail = nil }
                            }
                        }
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 640)
            #endif
        }
        .alert("Only 5 playlists can be pinned", isPresented: Binding(
            get: { appModel.pinLimitAlert },
            set: { appModel.pinLimitAlert = $0 }
        )) {
            Button("OK", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { appModel.playlistRename != nil },
            set: { if !$0 { appModel.playlistRename = nil } }
        )) {
            RenamePlaylistAlert()
        }
        .onChange(of: tabBinding.wrappedValue) { old, new in
            if new == .search { appModel.focusSearch = true }
            _ = old
        }
        #if os(macOS)
        .frame(minWidth: 1080, minHeight: 700)
        #endif
        .preferredColorScheme(appModel.preferredScheme)
        .environment(\.locale, appModel.appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appModel.appLanguage))
        .overlay {
            // One host, at the top of the tree, so a notice raised from a sheet or
            // a context menu is never clipped by the view that raised it. Same
            // reason upstream puts `QueueActionNoticeHost` above everything else.
            ToastHost()
        }
        // Playback failures are reported here rather than as a banner inside each
        // feed. `lastError` is a *playback* error — "Audio engine failed to start"
        // has nothing to do with a feed that happened to be on screen — and it
        // used to be rendered as a hard-coded red bar at the top of Home,
        // Explore and Search results, which is both the wrong place and the wrong
        // severity for a transient failure.
        .onChange(of: controller.lastError) { _, message in
            guard let message, !message.isEmpty else { return }
            toast.show(message, kind: .failure)
        }
    }

    @ViewBuilder
    private var shell: some View {
        #if os(macOS)
        // Music's Mac model: the player *is* the window. A hidden TabView
        // still injects the sidebar toggle into the toolbar, so it leaves
        // the hierarchy while the player is up. Home/Explore loaders live
        // on RootView and the tab is `@SceneStorage`, so dismiss does not
        // refetch or reset the selected tab.
        Group {
            if appModel.nowPlayingPresented {
                NowPlayingView()
            } else {
                tabShell
            }
        }
        #else
        Group {
            if appModel.settingsPresented {
                NavigationStack {
                    SettingsView(embedded: true)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { appModel.settingsPresented = false } label: {
                                    Label("Back", systemImage: "chevron.left")
                                }
                            }
                        }
                }
            } else { tabShell }
        }
            .environment(\.nowPlayingZoomNamespace, nowPlayingZoom)
            .modifier(NowPlayingTakeover(
                isPresented: Binding(
                    get: { appModel.nowPlayingPresented },
                    set: { appModel.nowPlayingPresented = $0 }
                ),
                zoomNamespace: nowPlayingZoom
            ))
        #endif
    }

    private var tabShell: some View {
        TabView(selection: tabBinding) {
            #if os(macOS)
            Tab(value: AppModel.Tab.home) {
                HomeView(feed: homeFeed).modifier(MacPlaybackChrome())
            } label: {
                // Upstream's own Home glyph, not the play triangle the UI spec
                // §6 claimed. `MainActivity.kt` puts `BitChordIcons.Home` on that
                // tab; the spec's inventory was wrong about it.
                sidebarLabel("Home", image: .bchHome)
            }
            Tab(value: AppModel.Tab.explore) {
                ExploreView().modifier(MacPlaybackChrome())
            } label: {
                sidebarLabel("Explore", image: .bchExplore)
            }
            TabSection("Library") {
                Tab(value: AppModel.Tab.libraryYouTube) {
                    LibraryView(lockedSection: .youtube).modifier(MacPlaybackChrome())
                } label: {
                    // Upstream has no distinct Recent glyph; the `bchLibrary`
                    // shelves are already taken by Albums below. The repeat-clock
                    // SF Symbol stays distinct from History's plain `bchClock`.
                    Label("Recent", systemImage: "clock.arrow.circlepath")
                }
                Tab(value: AppModel.Tab.librarySongs) {
                    LibraryView(lockedSection: .songs).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("Songs", image: .bchMusicNote)
                }
                Tab(value: AppModel.Tab.libraryAlbums) {
                    LibraryView(lockedSection: .albums).modifier(MacPlaybackChrome())
                } label: {
                    // Songs keeps the music note and Albums keeps the library
                    // shelves — the more fitting half of each conflicted pair.
                    sidebarLabel("Albums", image: .bchLibrary)
                }
                Tab(value: AppModel.Tab.libraryArtists) {
                    LibraryView(lockedSection: .artists).modifier(MacPlaybackChrome())
                } label: {
                    // Upstream has no distinct Artists glyph and the music note
                    // is already taken by Songs above; the mic reads as the
                    // performer rather than the track.
                    Label("Artists", systemImage: "music.mic")
                }
                Tab(value: AppModel.Tab.libraryPlaylists) {
                    LibraryView(lockedSection: .playlists).modifier(MacPlaybackChrome())
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
                Tab(value: AppModel.Tab.librarySubscriptions) {
                    LibraryView(lockedSection: .subscriptions).modifier(MacPlaybackChrome())
                } label: {
                    Label("Subscriptions", systemImage: "bell")
                }
                Tab(value: AppModel.Tab.libraryPodcasts) {
                    LibraryView(lockedSection: .podcasts).modifier(MacPlaybackChrome())
                } label: {
                    Label("Podcasts", systemImage: "radio")
                }
                Tab(value: AppModel.Tab.libraryOnDevice) {
                    LibraryView(lockedSection: .ondevice).modifier(MacPlaybackChrome())
                } label: {
                    Label("On Device", systemImage: "externaldrive")
                }
                Tab(value: AppModel.Tab.libraryHistory) {
                    LibraryView(lockedSection: .history).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("History", image: .bchClock)
                }
                // Only when there is a share. A sidebar row that leads to "not set up
                // yet" is a row that exists to be disappointing, and Sources is where
                // this is configured.
                if WebDavStore.shared.isConfigured {
                    Tab(value: AppModel.Tab.libraryWebDav) {
                        LibraryView(lockedSection: .webdav).modifier(MacPlaybackChrome())
                    } label: {
                        // An SF Symbol, not one of the `bch` images the other rows use.
                        // Upstream puts Material's `Cloud` on its WebDAV row and has no
                        // glyph to copy, and the Sources screen already draws this
                        // feature's row with the same symbol — so the two agree.
                        Label("WebDAV", systemImage: "cloud")
                    }
                }
            }
            Tab(value: AppModel.Tab.search, role: .search) {
                SearchView().modifier(MacPlaybackChrome())
            } label: {
                sidebarLabel("Search", image: .bchSearch)
            }
            #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                Tab("Home", image: "bch-home", value: AppModel.Tab.home) {
                    HomeView(feed: homeFeed).modifier(iPadPlaybackChrome())
                }
                Tab("Explore", image: "bch-explore", value: AppModel.Tab.explore) {
                    ExploreView().modifier(iPadPlaybackChrome())
                }
                TabSection("Library") {
                    Tab(value: AppModel.Tab.libraryYouTube) {
                        LibraryView(lockedSection: .youtube).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("Recent", systemImage: "clock.arrow.circlepath")
                    }
                    Tab("Songs", image: "bch-music-note", value: AppModel.Tab.librarySongs) {
                        LibraryView(lockedSection: .songs).modifier(iPadPlaybackChrome())
                    }
                    Tab("Albums", image: "bch-library", value: AppModel.Tab.libraryAlbums) {
                        LibraryView(lockedSection: .albums).modifier(iPadPlaybackChrome())
                    }
                    Tab(value: AppModel.Tab.libraryArtists) {
                        LibraryView(lockedSection: .artists).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("Artists", systemImage: "music.mic")
                    }
                    Tab(value: AppModel.Tab.libraryPlaylists) {
                        LibraryView(lockedSection: .playlists).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    Tab(value: AppModel.Tab.librarySubscriptions) {
                        LibraryView(lockedSection: .subscriptions).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("Subscriptions", systemImage: "bell")
                    }
                    Tab(value: AppModel.Tab.libraryPodcasts) {
                        LibraryView(lockedSection: .podcasts).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("Podcasts", systemImage: "radio")
                    }
                    Tab(value: AppModel.Tab.libraryOnDevice) {
                        LibraryView(lockedSection: .ondevice).modifier(iPadPlaybackChrome())
                    } label: {
                        Label("On Device", systemImage: "externaldrive")
                    }
                    Tab("History", image: "bch-clock", value: AppModel.Tab.libraryHistory) {
                        LibraryView(lockedSection: .history).modifier(iPadPlaybackChrome())
                    }
                    if WebDavStore.shared.isConfigured {
                        Tab(value: AppModel.Tab.libraryWebDav) {
                            LibraryView(lockedSection: .webdav).modifier(iPadPlaybackChrome())
                        } label: {
                            Label("WebDAV", systemImage: "cloud")
                        }
                    }
                }
                Tab("Search", image: "bch-search", value: AppModel.Tab.search, role: .search) {
                    SearchView().modifier(iPadPlaybackChrome())
                }
            } else {
                Tab("Home", image: "bch-home", value: AppModel.Tab.home) {
                    HomeView(feed: homeFeed)
                }
                Tab("Explore", image: "bch-explore", value: AppModel.Tab.explore) {
                    ExploreView()
                }
                Tab("Library", image: "bch-library", value: AppModel.Tab.library) {
                    LibraryView()
                }
                Tab("Search", image: "bch-search", value: AppModel.Tab.search, role: .search) {
                    SearchView()
                }
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .defaultAdaptableTabBarPlacement(.sidebar)
        #endif
        #if os(macOS)
        .environment(\.sidebarRowSize, .medium)
        .toolbar {
            if !appModel.nowPlayingPresented {
                ToolbarItem {
                    Button {
                        appModel.downloadManagerPresented = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .help("Downloads")
                }
                ToolbarItem {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        #endif
        .modifier(PlaybackPillMount())
    }


    #if os(macOS)
    private func sidebarLabel(_ title: String, image: ImageResource) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }
    #endif

    private var tabBinding: Binding<AppModel.Tab> {
        Binding(
            get: { resolvedTab(AppModel.Tab(rawValue: selection) ?? .home) },
            set: { newTab in
                // Upstream's `searchFocusTrigger`: re-tapping the tab that is
                // already selected focuses its search field rather than doing
                // nothing. A `TabView` cannot tell a re-tap from a no-op tap on
                // its own — the binding's setter only sees the value it is being
                // set to — so the "same tab again" case is recognised here.
                //
                // Only Search, because a field is the only thing on any of the
                // other tabs that a re-tap could reasonably mean. A re-tap that
                // scrolled Home to the top or popped the Library back would be
                // inventing behaviour nobody asked for.
                if newTab == .search, newTab == resolvedTab(AppModel.Tab(rawValue: selection) ?? .home) {
                    appModel.searchFocusTrigger &+= 1
                }
                selection = newTab.rawValue
            }
        )
    }

    private func resolvedTab(_ tab: AppModel.Tab) -> AppModel.Tab {
        #if os(macOS)
        if tab == .library { return .libraryYouTube }
        return tab
        #else
        if UIDevice.current.userInterfaceIdiom == .pad && tab == .library {
            return .libraryYouTube
        }
        return tab
        #endif
    }
}

/// The shared playback pill (UI spec §3.1/§3.2): `.tabViewBottomAccessory` on
/// iOS 26 — Music's own bottom accessory — with a material `safeAreaInset`
/// fallback below that floor. Same view, mounted per platform.
///
/// The accessory is tab-level, so it is unaffected by iPad sidebar
/// collapse/expand; inset mounting broke that and overlapped the tab bar.
struct PlaybackPillMount: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad mounts per tab (iPadPlaybackChrome): the tab-level
            // accessory container spans full width and stretches the pill,
            // and a TabView-level inset never reflows with the sidebar.
            content
        } else if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                PlaybackPill()
                    .frame(maxWidth: .infinity)
            }
        } else {
            fallbackMount(content)
        }
        #else
        // macOS: each tab content mounts the pill via `MacPlaybackChrome` so
        // it sits in the content column rather than crossing the sidebar.
        content
        #endif
    }

    private func fallbackMount(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            PlaybackPill()
                // Clamped to 720pt so it centers elegantly on iPad while taking
                // natural width on iPhone.
                .frame(maxWidth: 720)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
    }
}

#if os(iOS)
/// iPad per-tab pill mount. Lives inside the detail column — like
/// MacPlaybackChrome on macOS — so sidebar collapse/expand reflows it and it
/// stays centered on the main view. Content-sized at 620pt like Music's
/// compact pill instead of the full-width stretch of the tab-level
/// accessory container. No-op on iPhone, which mounts once at the TabView.
struct iPadPlaybackChrome: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.safeAreaInset(edge: .bottom) {
                PlaybackPill()
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
        }
    }
}
#endif

#if os(macOS)
/// Pins the playback pill to the tab's content column — the same place Music
/// keeps it — instead of spanning the whole window and covering the sidebar.
struct MacPlaybackChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            PlaybackPill()
                .frame(maxWidth: 900)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
    }
}
#endif

#if os(iOS)
/// iPhone: a large swipe-to-dismiss sheet that zooms out of the mini player
/// (WWDC 323 `MusicPlaybackView` pattern). iPad: a page-sized sheet.
struct NowPlayingTakeover: ViewModifier {
    @Binding var isPresented: Bool
    var zoomNamespace: Namespace.ID

    func body(content: Content) -> some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                // Full screen, unconditionally: `.page` sheet sizing renders
                // as a floating card on iPadOS 27, and only a cover is
                // guaranteed edge to edge.
                content.fullScreenCover(isPresented: $isPresented) {
                    NowPlayingView()
                        .navigationTransition(.zoom(sourceID: NowPlayingZoom.sourceID, in: zoomNamespace))
                }
            } else {
                content.sheet(isPresented: $isPresented) {
                    NowPlayingView()
                        .modifier(NowPlayingSheetSizing())
                        .navigationTransition(.zoom(sourceID: NowPlayingZoom.sourceID, in: zoomNamespace))
                }
            }
        }
    }
}

private struct NowPlayingSheetSizing: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationDragIndicator(.visible)
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }
}

enum NowPlayingZoom {
    static let sourceID = "now-playing"
}

private struct NowPlayingZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var nowPlayingZoomNamespace: Namespace.ID? {
        get { self[NowPlayingZoomNamespaceKey.self] }
        set { self[NowPlayingZoomNamespaceKey.self] = newValue }
    }
}
#endif

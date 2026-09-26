import SwiftUI
import BitChordShared

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
    @State private var exploreFeed = FeedLoader(.explore)
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
                YtMusicLoginView { header in
                    auth.accept(header)
                }
                .navigationTitle("Sign in")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { auth.loginPresented = false }
                    }
                }
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
        #if os(iOS)
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
                .environment(controller)
                .environment(appModel)
                .environment(auth)
                .id(settingsSession)
        }
        .onChange(of: settingsPresented) { _, presented in
            if !presented { settingsSession += 1 }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appModel.downloadManagerPresented = true
                } label: {
                    Image(systemName: DownloadStore.shared.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .help("Downloads")
            }
            ToolbarItem {
                Button {
                    settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        #endif
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
        tabShell
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
                ExploreView(feed: exploreFeed).modifier(MacPlaybackChrome())
            } label: {
                sidebarLabel("Explore", image: .bchExplore)
            }
            TabSection("Library") {
                Tab(value: AppModel.Tab.libraryYouTube) {
                    LibraryView(lockedSection: .youtube).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("Recent", image: .bchLibrary)
                }
                Tab(value: AppModel.Tab.librarySongs) {
                    LibraryView(lockedSection: .songs).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("Songs", image: .bchMusicNote)
                }
                Tab(value: AppModel.Tab.libraryAlbums) {
                    LibraryView(lockedSection: .albums).modifier(MacPlaybackChrome())
                } label: {
                    // Upstream glyphs throughout, per UI spec §6 — these two were
                    // SF Symbols sitting next to `.bchLibrary` and `.bchMusicNote`
                    // in the same sidebar, which read as a mistake.
                    sidebarLabel("Albums", image: .bchLibrary)
                }
                Tab(value: AppModel.Tab.libraryArtists) {
                    LibraryView(lockedSection: .artists).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("Artists", image: .bchMusicNote)
                }
                Tab(value: AppModel.Tab.libraryDownloads) {
                    LibraryView(lockedSection: .downloads).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("Downloads", image: .bchDownload)
                }
                Tab(value: AppModel.Tab.libraryHistory) {
                    LibraryView(lockedSection: .history).modifier(MacPlaybackChrome())
                } label: {
                    sidebarLabel("History", image: .bchClock)
                }
            }
            Tab(value: AppModel.Tab.search, role: .search) {
                SearchView().modifier(MacPlaybackChrome())
            } label: {
                sidebarLabel("Search", image: .bchSearch)
            }
            #else
            Tab("Home", image: "bch-home", value: AppModel.Tab.home) {
                HomeView(feed: homeFeed)
            }
            Tab("Explore", image: "bch-explore", value: AppModel.Tab.explore) {
                ExploreView(feed: exploreFeed)
            }
            Tab("Library", image: "bch-library", value: AppModel.Tab.library) {
                LibraryView()
            }
            Tab("Search", image: "bch-search", value: AppModel.Tab.search, role: .search) {
                SearchView()
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
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

    #if os(iOS)
    @State private var settingsPresented = false
    @State private var settingsSession = 0
    #endif

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
            set: { selection = $0.rawValue }
        )
    }

    private func resolvedTab(_ tab: AppModel.Tab) -> AppModel.Tab {
        #if os(macOS)
        if tab == .library { return .libraryYouTube }
        return tab
        #else
        return tab
        #endif
    }
}

/// The shared playback pill (UI spec §3.1/§3.2): `.tabViewBottomAccessory` on
/// iOS 26 — Music's own bottom accessory — with a material `safeAreaInset`
/// fallback on macOS and below that floor. Same view, mounted per platform.
struct PlaybackPillMount: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                PlaybackPill()
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
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }
}

#if os(macOS)
/// Pins the playback pill to the tab's content column — the same place Music
/// keeps it — instead of spanning the whole window and covering the sidebar.
struct MacPlaybackChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            PlaybackPill()
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
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
        content.sheet(isPresented: $isPresented) {
            NowPlayingView()
                .modifier(NowPlayingSheetSizing())
                .navigationTransition(.zoom(sourceID: NowPlayingZoom.sourceID, in: zoomNamespace))
        }
    }
}

private struct NowPlayingSheetSizing: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
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

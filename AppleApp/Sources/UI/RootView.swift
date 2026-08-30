import SwiftUI

/// Root navigation shell — one `TabView` with `.sidebarAdaptable` (UI spec §2):
/// bottom tab bar on iOS, Apple Music's leading sidebar on macOS, from a
/// single declaration. Exactly four canonical tabs, upstream icons, search
/// role pinned trailing. `@SceneStorage` keeps the last tab across launches.
struct RootView: View {
    @SceneStorage("bitchord.selectedTab") private var selection: Int = AppModel.Tab.home.rawValue
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth

    var body: some View {
        TabView(selection: tabBinding) {
            Tab("Home", image: "bch-play", value: AppModel.Tab.home) {
                HomeView()
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
        .tabViewStyle(.sidebarAdaptable)
        .modifier(PlaybackPillMount())
        .modifier(NowPlayingTakeover(isPresented: Binding(
            get: { appModel.nowPlayingPresented },
            set: { appModel.nowPlayingPresented = $0 }
        )))
        .onChange(of: appModel.requestedTab) { _, requested in
            guard let requested else { return }
            selection = requested.rawValue
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
        #if os(iOS)
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
                .id(settingsSession)
        }
        .onChange(of: settingsPresented) { _, presented in
            if !presented { settingsSession += 1 }
        }
        .toolbar {
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
        .toolbarVisibility(appModel.nowPlayingPresented ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .onOpenURL { url in
            // Widget deep link (spec §9): the artwork tap opens the player.
            if url.absoluteString.contains("open-player") {
                appModel.nowPlayingPresented = true
            }
        }
    }

    #if os(iOS)
    @State private var settingsPresented = false
    @State private var settingsSession = 0
    #endif

    private var tabBinding: Binding<AppModel.Tab> {
        Binding(
            get: { AppModel.Tab(rawValue: selection) ?? .home },
            set: { selection = $0.rawValue }
        )
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
        fallbackMount(content)
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

/// macOS's Now Playing is a full-window in-place takeover (UI spec §3.3);
/// on iOS it is a full-screen cover expanding from the pill.
struct NowPlayingTakeover: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            if isPresented {
                NowPlayingView()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
                    .zIndex(10)
            }
        }
        .animation(.spring(duration: 0.35), value: isPresented)
        #else
        content.fullScreenCover(isPresented: $isPresented) {
            NowPlayingView()
        }
        #endif
    }
}

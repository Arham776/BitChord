# BitChord Apple — UI Specification

Companion to `bitchord-apple-port-spec.md`. The port spec's §5 gives the *file-by-file* migration map (Compose screen → SwiftUI view). This document governs the parts §5 deliberately leaves open: the **navigation architecture**, the **tab system**, the **Apple Music-style chrome** for each platform, the **icon pipeline** (upstream icons, not SF Symbols), and the **deployment-target decisions** those choices force.

Read both together. Where this document and §5 disagree, this document wins for navigation/chrome; §5 wins for per-screen view naming.

---

## 1. Intent

Upstream BitChord's Android UI is ~90% complete, so this is a *translation*, not a redesign. The goal is to make it feel like a first-party Apple app by adopting **Apple Music's** navigation, chrome, and interaction patterns — the reference app the user has called out explicitly, and the one Apple itself leans on in recent WWDC navigation/design sessions.

Three hard constraints from the user drive everything below:

1. **Exactly four canonical tabs** — `Home` (upstream's tab is named **"Play"**; we rename it **Home**), `Explore`, `Library`, `Search`. No more, no fewer. Everything else is a pushed detail sheet or a sub-section inside one of these.
2. **Keep upstream's icons.** Do not substitute Apple SF Symbols for icons that already exist upstream. SF Symbols are acceptable only where a genuinely system-native affordance needs one (see §6).
3. **Follow Apple Music's UI/UX** for navigation structure, playback chrome, and platform nuance.

---

## 2. Navigation architecture — one `TabView`, adaptive

Use a single root `TabView` with `.tabViewStyle(.sidebarAdaptable)`. This is the exact pattern Apple demos for multiplatform tab/sidebar apps and it maps perfectly onto Apple Music's two shapes:

- **iOS / iPadOS** → a tab bar (bottom on iPhone; top-edge on iPadOS).
- **macOS** → a standard leading **sidebar**, which is precisely how Apple Music navigates on the Mac.

This means **one navigation declaration serves both platforms**, and the macOS build gets Music's sidebar "for free" instead of us hand-building a `NavigationSplitView`.

```swift
enum AppTab: Hashable { case home, explore, library, search }

struct RootView: View {
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", image: Image(.bchHome), value: .home) {
                HomeView()
            }
            Tab("Explore", image: Image(.bchExplore), value: .explore) {
                ExploreView()
            }
            Tab("Library", image: Image(.bchLibrary), value: .library) {
                LibraryView()
            }
            Tab("Search", image: Image(.bchSearch), value: .search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
```

Notes:

- Use the modern **`Tab(_:image:value:content:)`** initializer (iOS 18 / macOS 15), not the legacy `.tabItem`. It carries the selection value directly and is what `.sidebarAdaptable` expects.
- The Search tab is given **`role: .search`** so the system treats it as a search destination (pinned trailing placement in the sidebar / tab bar, correct accessibility). Because the user wants the **upstream** search glyph rather than the default magnifying-glass SF Symbol, we pass an explicit `image:` *and* the role. Verify at build time that `role:` + custom `image:` combine cleanly; if the role forces the system symbol in any context, drop `role:` and keep the custom image — the visual requirement outranks the role.
- On macOS, add the Library sub-destinations (Songs, Albums, Artists, Playlists, Downloads) as a **`TabSection`** under Library so they appear grouped in the sidebar — mirroring Apple Music's sidebar grouping. These are *sections*, not new canonical tabs: the tab bar / top level stays at four.
- **Do not** enable `.tabViewCustomization` (user-reorderable tabs) in v1. Keep the four tabs fixed so the information architecture stays canonical.

---

## 3. Playback chrome — the Apple Music split

Apple Music presents playback differently per platform. Match it.

### 3.1 iOS — mini-player above the tab bar

Music on iOS keeps a persistent **mini-player bar** hovering just above the tab bar; tapping it expands to the full player. Reproduce that:

- **iOS 26 / iPadOS 26 (preferred):** use **`.tabViewBottomAccessory { PlaybackPill() }`** on the root `TabView`, plus `.tabBarMinimizeBehavior(.onScrollDown)`. This is Apple's own Music-style bottom accessory API (the WWDC25 design session demos it with a `MusicPlaybackView`). Read `\.tabViewBottomAccessoryPlacement` inside `PlaybackPill` to adapt between inline and expanded layouts.
- **iOS 18–25 fallback:** attach the same `PlaybackPill` via `.safeAreaInset(edge: .bottom)` above the tab bar, styled with `.background(.ultraThinMaterial)`. Same view, two mounting points — gate with `if #available(iOS 26.0, *)`.

`PlaybackPill` ports upstream's `MiniPlayer.kt` (artwork thumbnail, title/artist, play-pause, next, loading spinner standing in for the play glyph, swipe-up to expand). Upstream also docks the player *beside* the content on tablets (`playerDocked` in `MainActivity.kt`) instead of covering it — keep that behavior for wide layouts (iPad landscape, macOS): when the window/size class is wide enough, Now Playing docks trailing rather than presenting over (§3.3).

### 3.2 macOS — floating bottom playback pill (same as iOS)

Live exploration of the current macOS Music app (macOS 26 Tahoe, August 2026) shows it no longer uses a top playback toolbar. The transport lives in a **persistent floating glass pill at the bottom of the window**, in the same position as the iOS mini-player:

- **Left cluster:** shuffle, previous, play/pause, next, repeat.
- **Center:** artwork thumbnail / brand mark — tapping it opens Now Playing ("Show Now Playing").
- **Right cluster:** lyrics, Up Next (queue), volume.

This is exactly what `.tabViewBottomAccessory` produces on macOS 26, and it means **one shared `PlaybackPill` component serves both platforms** — the iOS mini-player and the macOS pill are the same view:

- **macOS 26 / iOS 26:** `.tabViewBottomAccessory { PlaybackPill() }` on the root `TabView` (+ `.tabBarMinimizeBehavior(.onScrollDown)` on iOS).
- **macOS 15–25 / iOS 18–25 fallback:** mount the same `PlaybackPill` via `.safeAreaInset(edge: .bottom)` (or a bottom-aligned overlay above the tab bar), styled with `.background(.ultraThinMaterial)` and a capsule/continuous-corner clip. Gate with `if #available`.

The pill floats above content and persists across all tabs, exactly as Music behaves. Navigation (back/forward) is not in the pill — it lives in each tab's own `NavigationStack` toolbar, matching Music.

> This supersedes any "top playback bar" idea: current Music on both platforms converged on the bottom floating pill, so we do too, and get cross-platform code sharing for free.

### 3.3 Full Now Playing player

- **iOS:** present as a **full-screen cover** that expands from the pill (Music presents it as a draggable sheet). Use a `.sheet`/fullScreenCover with `.presentationDetents([.large])` and a matched-geometry expansion from the pill artwork. Background = ported `CanvasArtworkPlayer` + `MeshGradient` (§7).
- **macOS (live-observed, macOS 26):** Now Playing is a **full-window in-place takeover**, not a sheet — the whole window content swaps to the player. Layout observed: large artwork in the left column with the track title beneath it; a position slider with start/end timestamps; a transport row (shuffle / prev / play / next / repeat) below; a **lyrics pane filling the right half** ("Play a song to see lyrics here." when empty); volume slider top-right; dismiss (×) and mini-player toggles top-left; lyrics/queue toggle buttons bottom-right. Implement as an in-window state swap on the root view (e.g. `ZStack` overlay with a transition, or `navigationTransition`), with the artwork-driven background behind both columns.
- Port upstream `NowPlayingScreen.kt`, `CanvasArtworkPlayer.kt`, `MeshGradient.kt`, `ThinSlider.kt` per §5. `MeshGradient` is a native SwiftUI API on iOS 18 / macOS 15 — our raised floor (§9) makes it available without a `Canvas` fallback.

---

## 4. Screen inventory

Canonical tabs and their sub-screens. View names follow §5. (Upstream source paths confirmed in §5's table.)

| Tab | Root view | Pushed / presented sub-screens |
|---|---|---|
| **Home** (upstream "Play") | `HomeView` | `DetailView` (album/playlist/artist), Now Playing |
| **Explore** | `ExploreView` | `DetailView`, Now Playing |
| **Library** | `LibraryView` | `LibraryGridPage` ("See all" full-screen grid), `LocalMusicView`, `HistoryView`, `ReplayView` (year in review), `DetailView`, Now Playing |
| **Search** | `SearchView` | `DetailView`, Now Playing |

Cross-cutting (not tabs), all presented as sheets/dialogs from wherever invoked, matching upstream's usage: `SettingsView`, `SourcesView`, `AccountSettingsView`, `DiscordSettingsView` + `DiscordLoginView`, `YtMusicLoginView`, `SpotifyCanvasAuthView`, `AccountAndScrobblingView` (incl. Last.fm / ListenBrainz login), `SongActionsSheet`, `PlaylistPickerSheet`, `BrowseActionsSheet`, `DownloadManagerSheet`, `LyricsSourcesDialog`, `AppLanguageDialog`, `UpdateAvailableDialog`, `AccountAlerts`, `ReplayShareSheet`.

**Upstream's navigation model (verified from `MainActivity.kt`).** Upstream is a single-activity app: there is no back stack. The four tabs are an `Int` selection; everything else is a `remember`ed boolean or nullable ("show detail", "show now playing", "song actions for this song"…) that layers over the tabs. Two consequences for the port:

- Things upstream *layers* map to two Apple shapes, and the split follows affordance: pages the user drills *into* (`DetailView`, `HistoryView`, `LocalMusicView`, `LibraryGridPage`, `ReplayView`) become `NavigationStack` pushes inside the owning tab; things that are *actions on what's on screen* (all the sheets above, Now Playing) stay presentations (`.sheet`, full-screen cover, in-window takeover).
- Upstream signals worth keeping: re-tapping the already-selected Search tab focuses its search field (`searchFocusTrigger` — implement with `@SceneStorage` tab selection + a focus trigger); playback started from anywhere raises Now Playing only when the player isn't already docked (§3.1); the Discord dialog host sits at root level so its scrim covers the tab bar and pill.

---

## 5. Per-platform Apple Music nuances to adopt

Concrete behaviors worth copying, observed in Apple Music and in Apple's own sessions:

**macOS** (live-observed in Music on macOS 26, August 2026)
- Leading sidebar with grouped sections and small-caps grey headers; the account row sits at the sidebar's bottom. Our Library sub-destinations become a `TabSection` (§2).
- **Floating bottom playback pill**, not a top toolbar (§3.2).
- Search is a sidebar row; its content puts the search field at the **top of the content column** with a scope segmented control under it — not a toolbar field.
- Now Playing is a full-window in-place takeover (§3.3).
- Empty states are centered compositions: glyph + bold title + secondary subtitle + one bordered button.
- List rows highlight on hover; secondary text uses `.secondary` foreground.
- Right-click **context menus** on rows (Play, Play Next, Add to Queue, Add to Playlist, Get Info).
- Continuous corner rounding on artwork: `.clipShape(.rect(cornerRadius:, style: .continuous))`.
- Up Next / queue as a trailing **inspector** or popover (`.inspector(isPresented:)`).

**iOS**
- Bottom tab bar + mini-player above it (§3.1).
- Large navigation titles that collapse on scroll; `.searchable` where a search field is inline.
- Swipe-up on mini-player to expand to full player; swipe-down to dismiss.
- Full player uses artwork-driven background (§7).
- Haptics on transport actions (`UIImpactFeedbackGenerator` / `sensoryFeedback`).

**Both**
- Artwork-forward cards with continuous corners and subtle shadows.
- Material-backed chrome: `.background(.ultraThinMaterial)` for bars; on macOS an `NSVisualEffectView` wrapper where a specific material is needed.
- Typography: bold large titles, `.caption`/`.secondary` for metadata.

---

## 6. Icon pipeline — upstream icons, not SF Symbols

The user requires upstream's iconography. Pipeline:

1. **Source** upstream's icons: `ui/icons/BitChordIcons.kt` — a self-contained family of 16 hand-drawn glyphs (2.2px strokes, round caps/joins, "in the spirit of Telegram's modern icon set"), all pure vector path data. Verified inventory: tab glyphs **`Play`** (→ Home tab), **`Explore`** (compass), **`Library`** (three spines + one leaning — deliberately a thickened Apple Music library glyph), **`Search`**; player glyphs `Shuffle`, `Repeat`, `Infinity` (AutoPlay), `MusicNote`, `Lyrics`, `Heart`/`HeartFilled` (the player's like control, filled-and-stroked so the shape change survives any artwork); utility glyphs `ChevronRight`, `Plus`, `Check` (drawn on the same 14-unit span as `Plus` so save/unsave swaps don't jump), `Download`, `Clock`, `Pin`.
2. **Export** each icon's vector path to **SVG** (or PDF). Compose `ImageVector` path data converts losslessly to SVG path data (`moveTo`/`lineTo`/`arcToRelative`/`curveTo` → `M`/`L`/`A`/`C`). Stroke properties (2.2 weight, round cap/join) carry over as SVG stroke attributes.
3. **Import** into `AppleApp/Sources/UI/Assets.xcassets` as an image set with **Preserve Vector Data** on and **Render As: Template Image**. Template rendering lets the tab bar / toolbar tint them for selected/unselected and light/dark automatically — the same behavior SF Symbols would give, but with upstream's shapes.
4. **Expose** them as typed assets (Xcode generates `ImageResource`, e.g. `Image(.bchHome)`) or a thin `Image` extension.
5. Use these everywhere a tab, toolbar, or button icon appears.

**SF Symbols only where genuinely necessary** — i.e. system affordances upstream has no icon for, or where a role default is hard-wired. The documented exception list:

- **Transport glyphs** (`play.fill`, `pause.fill`, `forward.fill`, `backward.fill`): `BitChordIcons` deliberately has no pause/prev/next — upstream itself borrows Material's rounded glyphs for the mini-player and player, so using SF Symbols here *matches* upstream's behavior rather than departing from it.
- `chevron.left` for back navigation (upstream has only `ChevronRight`, and a disclosure hint rather than a navigation arrow); `square.and.arrow.up` for share; the `Tab(role: .search)` system symbol only if a custom image can't ride along.

Keep this list tiny and grow it only with a reason.

> **Optional refinement:** if tab-bar rendering of raw template images proves inflexible (e.g. no selected/unselected variants), convert the upstream SVGs into **custom SF Symbols** via the SF Symbols app. That keeps upstream's design while gaining symbol rendering behavior. Use only if the plain asset route falls short.

---

## 7. Theme & materials

- Port `ui/theme/Theme.kt` → `Theme.swift` and `ArtworkPalette.kt` → `ArtworkPalette.swift` (per §5). Colors, dark/light handling, and typography tokens come from upstream.
- **Artwork palette extraction** (driving the Now Playing background tint): if upstream depends on `androidx.palette`, reimplement as Swift color quantization (k-means over downsampled pixels) rather than porting the Android dependency.
- Frosted/blur surfaces → `.ultraThinMaterial` / `NSVisualEffectView` (§5 in the port spec). Upstream's glass is the **Haze** library (`dev.chrisbanes.haze`, `HazeMaterials.regular` over live content) — the closest Apple equivalent is `.regularMaterial`/`.ultraThinMaterial` over the same content. Upstream's `reduceDynamicBlur` setting (swap glass for a solid surface) maps to toggling the material off; its `reduceAnimation` setting (snap instead of spring) maps to `accessibilityReduceMotion`-driven animation switching.
- **Loading states**: port `Skeletons.kt`'s shimmer placeholders as SwiftUI shimmer views — upstream uses them on every feed, so they are part of the look, not an edge case.
- **Haptics**: port `ui/haptics/Haptics.kt`'s named events (`Select`, `Tick`, …) onto `UIImpactFeedbackGenerator`/`sensoryFeedback` (iOS); macOS degrades gracefully to no-op unless a trackpad gesture warrants `NSHapticFeedbackManager`.
- **`MeshGradient`** for the animated Now Playing backdrop — native on iOS 18 / macOS 15, which our floor (§9) satisfies.

---

## 8. State & view models

No change from the port spec §5: portable state-derivation lives in `shared` (common Kotlin, `StateFlow`, exposed to Swift via KMP-NativeCoroutines); platform glue is native Swift `@Observable` view models per screen. The tab **selection** is app-level `@State`/`@Observable` (or `@SceneStorage` to persist the last tab across launches — adopt `@SceneStorage`).

---

## 9. Deployment targets — raise the floor

The navigation APIs this spec depends on require a higher floor than the current scaffold (iOS 17.0 / macOS 14.0):

| API | Minimum |
|---|---|
| `Tab`, `TabSection`, `.tabViewStyle(.sidebarAdaptable)`, `Tab(role: .search)` | iOS 18.0 / macOS 15.0 |
| `MeshGradient` | iOS 18.0 / macOS 15.0 |
| `.tabViewBottomAccessory`, `.tabBarMinimizeBehavior`, Liquid Glass (`glassEffect`, `GlassEffectContainer`) | iOS 26.0 / macOS 26.0 |

**Decision:** raise the app's minimum to **iOS 18.0 / macOS 15.0**. This unlocks `Tab`/`TabSection`/`sidebarAdaptable`/search-role/`MeshGradient` unconditionally. iOS 26 / macOS 26 goodies (bottom accessory, Liquid Glass) are gated behind `if #available(iOS 26.0, macOS 26.0, *)` with iOS-18-era material fallbacks, so the app still runs everywhere we support.

The **widget extension** keeps its iOS 17 / macOS 14 floor (port spec §9) — interactive widgets need ≥ iOS 17 / macOS 14, which is below the app floor, so nothing regresses.

Update `AppleApp/project.yml` accordingly:
```yaml
deploymentTarget:
  iOS: "18.0"
  macOS: "15.0"
```
(and confirm the widget target's deployment stays at its floor if xcodegen needs it split.)

---

## 10. WWDC / Apple references

Sessions and samples this spec draws from — useful as implementation references and code sources:

- **WWDC24 — "Elevate your tab and sidebar experience in iPadOS"** (session 10147): the `Tab`, `TabSection`, `.sidebarAdaptable`, `Tab(role: .search)`, and tab-customization APIs. https://developer.apple.com/videos/play/wwdc2024/10147/
- **WWDC25 — "Build a SwiftUI app with the new design"** (session 323): Liquid Glass, `.tabViewBottomAccessory` (demoed with a Music-style playback view), `.tabBarMinimizeBehavior`, search toolbar behavior. https://developer.apple.com/videos/play/wwdc2025/323/
- **Apple docs — "Enhancing your app's content with tab navigation"**: https://developer.apple.com/documentation/swiftui/enhancing-your-app-content-with-tab-navigation
- **Food Truck sample** (WWDC22, multiplatform SwiftUI navigation): https://github.com/apple/sample-food-truck
- **Backyard Birds sample** (SwiftUI + widgets): https://developer.apple.com/documentation/swiftui/backyard-birds-sample
- **Landmarks — Liquid Glass update** (WWDC25 companion sample).

---

## 11. Build order

1. **Chrome + navigation shell**: root `TabView` (`.sidebarAdaptable`), four tabs with upstream icons, `@SceneStorage` selection, macOS sidebar grouping. Gate: four tabs render and switch on both platforms.
2. **Playback chrome**: the shared `PlaybackPill` (§3.1/§3.2) — `.tabViewBottomAccessory` on 26+, `safeAreaInset` fallback below — wired to placeholder transport state on both platforms. Gate: pill visible above content on both platforms and controls respond.
3. **Tab content shells**: `HomeView`, `ExploreView`, `LibraryView`, `SearchView` with upstream layout, fed by shared view models.
4. **Now Playing**: full player — iOS full-screen cover expanding from the pill, macOS full-window in-place takeover (§3.3), docked-trailing variant in wide layouts — with `MeshGradient` backdrop, `ThinSlider`, transport.
5. **Detail + supporting surfaces**: `DetailView`, `HistoryView`, `LibraryGridPage`, `ReplayView`, downloads manager, settings, sources, auth, lyrics/playlist/action sheets.
6. **Polish**: artwork palette, materials, hover/context-menu nuances, haptics, animations, continuous corners.

Each step is independently buildable; cross-reference the port spec §8 milestone 12 for where this slots in the overall sequence.

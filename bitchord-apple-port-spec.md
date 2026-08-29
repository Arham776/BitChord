# BitChord Apple Port — Technical Specification

**Target:** macOS (primary), iOS (secondary/stretch — may eventually replace YouTube Music client for personal use)
**Architecture:** Kotlin Multiplatform shared logic core (`shared`) + a Rust native core (`native-core`) for decode/analysis/mixing + native SwiftUI frontend on Apple platforms, Android app unchanged
**Upstream:** github.com/kushagrasinghx/BitChord, vendored via git submodule at a pinned commit for reference/diffing — NOT a live build dependency
**Audience for this document:** a coding agent executing the port. Sections are ordered by build sequence. Do not skip validation steps between phases.

---

## 0. Repository Layout

```
bitchord-apple/
├── vendor/
│   └── bitchord-upstream/        # git submodule, kushagrasinghx/BitChord, pinned SHA — reference only, never built
├── shared/                        # new KMP module — this repo's own source of truth
│   ├── build.gradle.kts
│   └── src/
│       ├── commonMain/kotlin/     # platform-agnostic logic
│       ├── androidMain/kotlin/    # unused initially — placeholder for future Android reunification
│       ├── iosMain/kotlin/        # iOS-specific actuals
│       └── macosMain/kotlin/      # macOS-specific actuals
├── native-core/                   # Rust crate — merges analyzer + playback decode/mix engine, one UniFFI boundary
│   ├── Cargo.toml
│   ├── src/
│   │   ├── analyzer/               # ported logic from upstream native/analyzer C++ (tempo, mel spectrogram, vocal separation), reimplemented in Rust
│   │   ├── decode/                 # symphonia-based decode pipeline, streaming source reader
│   │   ├── mixer/                  # dedicated audio thread: cpal output + gapless/crossfade mixing (oddio as candidate mixer layer — see §3, gated by §8 milestone-4 spike)
│   │   ├── spatial/                # SpatialRenderer: Rust port of upstream SpatialAudioProcessor DSP (mid/side widening + crossfeed), applied per-stream pre-mix (§3.3)
│   │   ├── transition_filter/      # TransitionFilter: Rust port of upstream TransitionFilterProcessor DSP (Butterworth LP/HP with gliding cutoffs), per-stream pre-mix (§3.5)
│   │   └── lib.rs                  # UniFFI-annotated public API (#[uniffi::export]) — the entire FFI surface, no hand-written C header
│   └── uniffi-bindgen.rs           # small bin target that invokes uniffi's bindgen to (re)generate Swift + Kotlin bindings on demand
├── AppleApp/                      # SwiftUI app, SPM-based, xcodegen-managed project file
│   ├── Package.swift
│   ├── project.yml                # xcodegen spec — app target + Widget extension target, shared App Group entitlement
│   └── Sources/
│       ├── App/                   # app entry, scenes, URL intake (onOpenURL → MusicLink parser, §1.3)
│       ├── PlaybackSession/       # thin Swift wrapper: AVAudioSession, MPNowPlayingInfoCenter, interruption handling — calls into native-core for actual audio
│       ├── SpatialAudio/          # iOS-only HeadTracker: CMHeadphoneMotionManager head pose → native-core, with silent fallback when unavailable (§3.3)
│       ├── Tagging/               # fallback location only — preferred tagging path is `lofty` inside native-core (§4)
│       ├── UI/                    # SwiftUI views, one folder per screen
│       └── Widget/                # WidgetKit extension (iOS + macOS): TimelineProvider, square/wide families, App Intents (§9) — reads App Group state only, never links native-core
├── scripts/
│   ├── build-shared-framework.sh  # Kotlin/Native → XCFramework
│   └── build-native-core.sh       # cargo build --release per Apple target (aarch64-apple-ios, aarch64-apple-ios-sim, aarch64-apple-darwin) + `cargo swift package` (or uniffi-bindgen + xcodebuild -create-xcframework) + uniffi Kotlin bindings for the shared module
└── .gitmodules
```

**Submodule setup:**
```
git submodule add https://github.com/kushagrasinghx/BitChord vendor/bitchord-upstream
git submodule update --init --recursive
```
Pin to a specific commit deliberately (not tracking a branch). Bumping upstream is a manual, reviewed action: check out the new commit, diff `vendor/bitchord-upstream` against the last-ported state, re-adapt anything that changed in files you've already copied into `shared/`.

**Do not** create a Gradle composite build or `includeBuild` pointing at `vendor/bitchord-upstream`. It is not structured as a library module (`com.android.application`, not `com.android.library`) and is not a dependency target. Treat it purely as a browsable reference tree for copy-adapt work and future diffing.

---

## 1. Shared KMP Module (`shared/`)

### 1.1 Gradle setup
- Kotlin Multiplatform plugin, targets: `iosArm64`, `iosSimulatorArm64`, `macosArm64` (add `macosX64`/`iosX64` only if Intel support is required).
- `binaries.framework { baseName = "BitChordShared"; isStatic = true }` on each Apple target, registered with the Kotlin Gradle Plugin's built-in `XCFramework()` API (`org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework`); `./scripts/build-shared-framework.sh` invokes the generated `assembleBitChordSharedXCFramework` task and copies the output into `AppleApp/Frameworks/`. Note KGP 2.x emits **separate `debug/` and `release/` xcframeworks** — the script packages one configuration at a time (default `debug`, override with `CONFIG=release`); do not try to merge both into one xcframework, `xcodebuild -create-xcframework` rejects duplicate platform identifiers.
- Dependencies to add in `commonMain`: `ktor-client-core` + `ktor-client-darwin` (Apple engine), `kotlinx-serialization-json`, `kotlinx-coroutines-core`, `multiplatform-settings` (replaces Android `SharedPreferences`/DataStore usage), `sqldelight` if any local DB/cache needs a portable schema (check upstream for Room usage — if present, migrate to SQLDelight, do not attempt to port Room directly, it's Android-only).
- Do **not** add coroutines' `Flow` exposure directly to the exported framework surface without wrapping — Kotlin/Native's ObjC export does not bridge suspend functions or Flow cleanly. Add `KMP-NativeCoroutines` (Rick Clephas' library: plugin `com.rickclephas.kmp.nativecoroutines`, artifacts `com.rickclephas.kmp:kmp-nativecoroutines-core` / `-annotations`; it is *not* a `co.touchlab` artifact — co.touchlab makes SKIE) as a dependency and annotate every publicly exported suspend function / Flow-returning function with `@NativeCoroutines`.

### 1.2 File migration map — copy & adapt (mechanical, low risk)

For each file below: copy from `vendor/bitchord-upstream/app/src/main/java/com/music/bitchord/...` into the corresponding `shared/src/commonMain/kotlin/...` package, then apply the listed adaptation.

| Upstream path | Target package in `shared` | Adaptation required |
|---|---|---|
| `data/innertube/Innertube.kt`, `InnertubeParser.kt`, `PlaybackTracker.kt`, `PlayerClient.kt`, `StreamResolver.kt` | `data.innertube` | Replace any Android-specific `HttpURLConnection`/OkHttp usage in `Http.kt` (see below) with Ktor client calls. Keep parsing logic (JSON structure knowledge) unchanged. |
| `data/Http.kt` | `data.http` | Rewrite as a thin Ktor `HttpClient` wrapper (`HttpClient(Darwin)` on Apple, keep an `expect`/`actual` if Android target is ever reunified). Preserve existing header/user-agent logic — Innertube is header-sensitive. |
| `data/lyrics/*.kt` (all 10 files) | `data.lyrics` | Pure HTTP/parsing — swap HTTP client only, no logic changes expected. |
| `data/scrobbling/LastFM.kt`, `ListenBrainzManager.kt`, `ScrobbleManager.kt` | `data.scrobbling` | Swap HTTP client. If `ScrobbleManager` persists a local queue (offline scrobble retry), replace Android storage with `multiplatform-settings` or SQLDelight. |
| `data/canvas/*.kt` (all 4 files) | `data.canvas` | Swap HTTP client only. |
| `data/model/Models.kt` | `data.model` | Should port unchanged — verify no Android-specific annotations (`@Parcelize`, etc.) are present; strip if so. |
| `data/sources/*.kt` (ModuleSource, MusicSource, SourceKind, SourceRegistry, SourceResolver, TrackMatcher, YouTubeSource) | `data.sources` | Logic-only, ports unchanged. |
| `data/sources/module/ModuleIndex.kt`, `ModuleManager.kt`, `ModuleResults.kt`, `SpineModule.kt` | `data.sources.module` | Ports unchanged. `QuickJsExecutor.kt` is excluded — see §1.3. |
| `data/settings/AppSettings.kt`, `SearchHistory.kt` | `data.settings` | Replace Android DataStore/SharedPreferences backing with `multiplatform-settings`. Keep the public API (get/set surface) identical so callers don't change. |
| `com/my/kizzy/gateway/*` (DiscordWebSocket + entities), `com/my/kizzy/rpc/*`, `com/my/kizzy/utils/Ext.kt` | `discord.gateway`, `discord.rpc` | Swap WebSocket transport to `ktor-client-websockets`. Serialization (kotlinx.serialization) should already be portable — verify no `android.os` imports slipped in. |
| `playback/smart/TrackAnalyzer.kt`, `TransitionPlanner.kt`, `TransitionPolicy.kt`, `TrackFeatures.kt`, `BeatTracker.kt`, `TrackAnalysis.kt` | `playback.smart` | Decision/state logic + a pure data model (`TrackAnalysis.kt` has no Android dependencies) — ports unchanged. `BeatTracker`/`TrackAnalyzer` will call into the native analyzer bridge (§2) via `expect`/`actual` instead of JNI. |
| `playback/QueueBuilder.kt`, `QueueShuffle.kt` | `playback.queue` | Pure logic, ports unchanged. |
| `playback/smart/AnalysisStore.kt` | `playback.smart` | Per-track analysis cache as JSON files (one file per hashed track ID, capped, with a negative cache). Only the `Context` storage path and `Log` calls are Android — rebase on kotlinx.serialization JSON plus the `expect`/`actual` cache dir from §1.3; keep the one-file-per-track + cap semantics. |
| `playback/Autoplay.kt` | `playback.autoplay` | Radio-style pre-buffering of related tracks (`YtMusicRepository.radio`, `QueueBuilder.extend`, `fromAutoplay` flagging, `MAX_QUEUED_AUTOPLAY` cap). Plain suspend Kotlin with no framework imports — ports unchanged once innertube/sources/queue are in place. |
| `playback/PlayerDeepLink.kt` | `playback` | One-shot "open the full player" pending state (`StateFlow`, consumed-once, cleared via `handled()`) — portable logic, ports unchanged. The Android Intent-extra intake becomes the widget deep link on Apple (§9); upstream's widget artwork tap is the only thing that sets it. |
| `widget/MediaWidget.kt`, `MediaWidgetActions.kt`, `MediaWidgetArt.kt`, `MediaWidgetSnapshot.kt` | — (not copied) | Android `RemoteViews`/`AppWidget`/`Bitmap` code — no portable logic to copy; the widget's contract is reimplemented natively in §9 (WidgetKit). The only residue that survives the platform swap is the snapshot field set (`WidgetStatePublisher`, §3.2), the action rules (§9), and the `PlayerDeepLink` one-shot (previous row). |
| `data/AppUpdateChecker.kt`, `DebugLog.kt`, `NerdStats.kt`, `TrackLog.kt` | `data.util` | Verify no Android `Log`/`Context` dependency; if present, define `expect fun platformLog(...)`.

**Validation for this section:** after copy-adapt, `shared` commonMain must compile against `iosArm64`/`macosArm64` targets with zero `expect` left unimplemented, and zero Android SDK imports remaining anywhere in `commonMain`.

### 1.3 Files requiring an `expect`/`actual` boundary, not a straight copy

| File | Why | Actual implementation (Apple side) |
|---|---|---|
| `data/sources/module/QuickJsExecutor.kt` | Android-specific QuickJS JNI binding for the module-source JS scripting sandbox | Implement `actual` using `JavaScriptCore` (`JSContext`/`JSValue`, built into iOS/macOS — no external dependency needed). API surface (`expect class ModuleScriptExecutor { fun eval(...) }`) must match what `ModuleManager.kt` already calls. |
| `data/settings/*` storage backing | Android DataStore | `actual` via `multiplatform-settings`'s `NSUserDefaultsSettings` on Apple. |
| `data/AppSettings.kt` / any `Context`-dependent path resolution (cache dirs, downloads dir) | Android `Context.filesDir` etc. | `actual fun platformCacheDir(): String` returning `NSSearchPathForDirectoriesInDomains` equivalent via Kotlin/Native's `platform.Foundation` interop. |
| `playback/smart/TrackAnalyzer.kt`, `BeatTracker.kt`, `VocalTracker.kt`, `MelSpectrogram.kt` (the JNI-calling parts only — decision logic stays common) | Currently call into `native/analyzer` C++ via JNI | `actual` implementations call into `native-core` (Rust) via the generated UniFFI Kotlin bindings instead of JNI (§2). Decision logic (what to do with the analysis result) stays in `commonMain`; only the "call native code" seam moves. |
| `playback/smart/AudioDecoder.kt` + `playback/smart/LocalAudioSource.kt` | Analysis input path: region-decode of cached/local audio via `MediaCodec`/`MediaExtractor`/`ContentResolver` | `actual` calls into `native-core`: seek-bounded region decode via `symphonia` returning float PCM + sample rate + effective start, in mono and split-channel variants, `null` on failure — this contract is lifted verbatim from upstream's own documentation of `AudioDecoder`, which `TrackAnalyzer` depends on. Local files on Apple are plain paths (security-scoped bookmarks from §5's `LocalMusicView`); no `ContentResolver` equivalent is needed. |
| `playback/MusicLink.kt` | External-request relay: parses YouTube-family URLs (`watch?v=`, `youtu.be`, Shorts, embed, `/v/`, `list=` playlists, channel/browse, search), shared text, and voice queries; built on Android `Intent`/`Uri`/`SearchManager` | Split: URL parsing + pending-request state → `commonMain` (pure logic); the intake seam is Apple-side — SwiftUI `onOpenURL` (iOS) and `NSAppleEventManager` URL events (macOS) in `AppleApp/Sources/App/` feed the parser. |

---

## 2. Native Core — Analyzer (`native-core/src/analyzer/`) and the FFI approach (UniFFI)

Upstream's `native/analyzer/*.cpp` (audio_analysis, mel_spectrogram, resampler, tempo_analysis, vocal_spectrogram) plus the ONNX models (`beat_this_int8.onnx`, `vocals_umxhq_int8.onnx`) are portable signal-processing logic — not JNI-locked, not C++-locked. Reimplemented in Rust here rather than cinterop'd as C++, so the analyzer shares one crate with the playback engine in §3, instead of maintaining two separate native integration surfaces.

**FFI mechanism — use UniFFI (mozilla/uniffi-rs), not hand-written cbindgen + Kotlin/Native cinterop.** UniFFI generates both Swift and Kotlin bindings directly from `#[uniffi::export]`-annotated Rust — the same tool Mozilla uses to share Rust code between Firefox for Android and Firefox iOS in production. This removes an entire layer of handwritten glue (no manually authored C header, no manually authored `.def` file, no manually written `expect`/`actual` cinterop shims for the native-core boundary specifically): you annotate the Rust API surface once, and `cargo run --bin uniffi-bindgen generate ... -l swift` / `-l kotlin` produce idiomatic, typed bindings for both languages in one step. Because the Kotlin bindings work with Kotlin/Native, the generated API is what `shared`'s `expect`/`actual` declarations call into — the `expect` layer from §1.3 stays, but it's now calling a generated, typed Kotlin API rather than a raw C function you cinterop'd by hand. This also sets up a real payoff for a future Android reunification: the same crate can emit Android-JVM Kotlin bindings from the same `#[uniffi::export]` surface with no additional annotation work, at which point `native-core` could replace Media3 there too.

Steps:
1. Treat `vendor/bitchord-upstream/native/analyzer/*.{cpp,h}` as the algorithmic reference, not code to compile. Port the DSP logic (mel spectrogram computation, resampling, tempo/beat detection, vocal spectrogram extraction) to Rust by hand, checking numeric behavior against the C++ reference at each step (see validation below) rather than doing a blind line-by-line translation.
2. Use the `ort` crate (Rust ONNX Runtime binding) to run `beat_this_int8.onnx` and `vocals_umxhq_int8.onnx` — same models, no retraining/reconversion needed. Copy the two `.onnx` files into `AppleApp/Resources/Models/`, bundled into the final app; the Swift side resolves the bundle resource path at startup and passes it into `native-core` (Rust has no bundle APIs), which loads the models from there at runtime.
3. Keep the exposed API surface as narrow as the JNI surface currently is in `app/src/main/cpp/jni/*.cpp` — those three JNI files (`analysis_jni.cpp`, `mel_jni.cpp`, `vocal_jni.cpp`) are the reference for exactly which entry points are actually called from Kotlin today (analyze-track, get-mel-spectrogram, get-tempo, get-vocal-mask). Annotate exactly those functions with `#[uniffi::export]` in `native-core/src/lib.rs`, and no more.
4. Set up the `uniffi-bindgen.rs` binary target per UniFFI's standard pattern (a small `fn main()` that proxies to `uniffi::uniffi_bindgen_main()` or equivalent), so bindings can be regenerated on demand as the API evolves rather than hand-maintained. Implement the `expect` declarations from §1.3 as thin calls into the generated Kotlin bindings.
5. Build via `scripts/build-native-core.sh`: `cargo build --release --target aarch64-apple-ios`, `--target aarch64-apple-ios-sim`, `--target aarch64-apple-darwin` (add `x86_64-apple-darwin` only if Intel Mac support matters), then either `cargo swift package` (a UniFFI-ecosystem cargo plugin that builds an SPM Swift package directly, no manual XCFramework assembly) or `uniffi-bindgen` + `xcodebuild -create-xcframework` if finer build control is needed. Also run the Kotlin binding generation step so `shared`'s Kotlin/Native compilation links against it.

**Validation:** run the existing upstream unit test fixtures for beat detection / vocal separation (if any exist under `app/src/test`) against the Rust reimplementation on macOS and confirm numeric parity (within acceptable float tolerance) with the Android C++/JNI path, using the same ONNX models and same test tracks. Do not proceed to §3 until this parity check passes — a subtly wrong resampler or mel-spectrogram implementation will silently degrade Automix quality without an obvious build-time signal.

---

## 3. Playback Engine — Rust core (`native-core/src/decode/`, `native-core/src/mixer/`, `native-core/src/spatial/`, `native-core/src/transition_filter/`) + thin native Swift session layer

This is the largest genuinely new-engineering piece of this project regardless of language choice — nothing hands you gapless+crossfade+chunked-streaming for free on any platform. `PlaybackService.kt`, `PlayerConnection.kt`, `CrossfadeController.kt`, `ChunkedDataSource.kt`, `AudioCache.kt`, `DynamicLruCacheEvictor.kt`, `QualityUpgrade.kt`, `StreamChoice.kt`, `SleepTimer.kt`, `LastPlayed.kt` are all built on Media3/ExoPlayer. Do not attempt to port these files — reimplement the capability, reusing only the *decisions* already made by `playback/smart/*` (already ported to `shared` per §1.2). The two Media3 `AudioProcessor`s are the exception to "reimplement, don't port": `SpatialAudioProcessor.kt` and `TransitionFilterProcessor.kt` contain hand-written DSP whose math ports directly — see §3.3 and §3.5.

**Split of responsibility, and why:** the decode/mix/cache engine goes in `native-core` (Rust) so it shares one crate and one UniFFI boundary with the analyzer (§2), and so a future Android reunification could reuse the same engine via generated Kotlin bindings instead of Media3. What does **not** move to Rust: OS-level session integration (backgrounding, lock-screen controls, interruption handling) has no Rust equivalent and stays native Swift — `cpal`/`symphonia` give you decode and raw audio output, not `AVAudioSession` or `MPNowPlayingInfoCenter`.

### 3.1 `native-core` components (Rust)

| Component | Responsibility | Implementation approach |
|---|---|---|
| `StreamingReader` | Pull chunked HTTP audio data (from `StreamResolver`'s resolved URL, via `shared`) into a buffered, seekable reader | Implement `symphonia::core::io::MediaSource` backed by a background HTTP streaming task (`reqwest` or `ureq` with a ring-buffer/backpressure scheme) so `symphonia` can decode while data is still arriving. This is genuinely new work — `symphonia` assumes a `MediaSource`, it doesn't ship a network-streaming one — comparable in effort to what the equivalent Swift `AVAudioSourceNode` approach would have required; the payoff is in decode format coverage, not this piece. |
| `Decoder` | Decode compressed audio (FLAC/MP3/AAC/Opus/Vorbis) to PCM | `symphonia`'s format/codec registry. **Verify WebM/Opus coverage specifically before committing** — that is the riskiest gap, since symphonia's support maturity varies by codec and WebM/Opus is a common YouTube Music stream container; confirm against real stream formats early (§8 gate) rather than assuming full parity with ExoPlayer's format support. AAC/`.m4a` risk is substantially de-risked by Keet (`amsdias/Keet`), which decodes AAC/M4A — plus ALAC and AIFF — on symphonia 0.6 with SIMD in production. Include ALAC/AIFF in coverage targets for local library files (§5 `LocalMusicScreen`), which are common in macOS libraries. |
| `DiskCache` | LRU-cached downloaded/streamed audio on disk, keyed by track ID + quality | File-based cache with a metadata index (reuse SQLDelight from `shared` if already added, or a simple index file read/written from Rust). Cache *policy* (what to evict, size limits) can stay as portable Kotlin logic in `shared`, called from Swift, which tells `native-core` what to evict — only the file I/O and decode-buffer caching is Rust. Replaces `AudioCache.kt` + `DynamicLruCacheEvictor.kt`. |
| `Mixer` | Two-track gapless transition + crossfade, raw audio output | `cpal` output stream (`CoreAudio` backend on Apple); `cpal` provides no mixer graph. Candidate foundation: **`oddio`** on top of `cpal` — its `Mixer` schedules multiple concurrent signals sample-accurately, and a thread-safe `MixerControl` handle performs start/stop/seek and `Gain` changes from the control thread without touching the render callback, which is exactly the two-player gapless/crossfade topology. **Adoption is gated by the §8 milestone-4 spike:** oddio's last release was 2023-10, so the spike must judge API fit and maintenance risk before committing. Fallback (already scoped, no downstream changes if triggered): hand-rolled blending — manually mix two PCM buffers sample-by-sample over the transition window directly in the `cpal` render callback. Whichever path is chosen, use an **equal-power crossfade curve**, not linear gain blending — linear crossfades perceptibly dip in volume mid-transition; Keet uses equal-power. Moving to Rust does not shrink this piece of work either way; it relocates it into a callback you write once instead of against `AVAudioEngine`'s node graph. |
| `SpatialRenderer` | Upstream `SpatialAudioProcessor` DSP: mid/side widening + delayed low-passed crossfeed, `enabled` toggle, per-stream (§3.3) | Small DSP stage wrapping each decode stream **before** the `Mixer` (mirrors upstream's two instances, one per ExoPlayer). Port the math and tuning constants verbatim in f32; disabled = sample-identical passthrough; optional head-tracking input from the Swift layer on iOS (§3.3). |
| `TransitionFilter` | Upstream `TransitionFilterProcessor` DSP: Butterworth low-pass/high-pass pair with geometrically gliding cutoffs, driven during transitions (§3.5) | Per-stream stage alongside `SpatialRenderer`; topology and constants port verbatim; degenerates to buffer copy when parked; cutoff targets driven by the crossfade execution loop inside the `Mixer`. |
| `lib.rs` | Narrow UniFFI surface | Playback control (play/pause/seek/queue-next-track/set-crossfade-window/set-spatial-enabled/head-rotation), analysis region decode (§1.3), and the analyzer functions from §2 — all annotated `#[uniffi::export]` on the one public API (§2). Swift and Kotlin bindings are generated from that same surface — no hand-written C header, no `.def` file. |

**Existence proof — Keet (`amsdias/Keet`):** a solo-maintained Rust terminal player that ships gapless playback (sample-accurate track transitions), equal-power crossfade, ReplayGain with peak-based clipping prevention, and MP3/FLAC/WAV/OGG/AAC-M4A/ALAC/AIFF decode (symphonia 0.6 with SIMD enabled) on macOS/Windows/Linux. It is not evidence about oddio or UniFFI specifically, but it proves this class of Rust audio stack delivers gapless + crossfade in practice, and it is a concrete codebase to crib decode-pipeline and transition patterns from. Note where its coverage stops: desktop only — no iOS build, no `AVAudioSession`/now-playing integration — which is precisely why the Swift session layer in §3.2 exists and is unaffected by the Rust decision. Treat Keet as browsable reference material (same posture as `vendor/bitchord-upstream`), not a dependency.

### 3.2 Swift session layer (`AppleApp/Sources/PlaybackSession/`)

| Component | Responsibility | Implementation approach |
|---|---|---|
| `NowPlayingController` | Lock-screen / Bluetooth / media-key controls | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, fed by playback state read from `native-core` via `shared`. Direct, low-effort equivalent of `PlaybackService.kt`'s `MediaSession` usage — unaffected by the Rust decision. |
| `AudioSessionManager` | Focus/interruption handling (calls, other apps) | `AVAudioSession` category (`.playback`) + interruption notifications, pausing/resuming the `native-core` mixer across the FFI boundary on interruption callbacks. Equivalent of Android audio focus in `PlaybackService.kt` — also unaffected by the Rust decision. |
| `SleepTimerController` | Timed playback stop | Trivial `Timer`-based reimplementation of `SleepTimer.kt`, calls into `native-core`'s pause function. |
| `QualityUpgradeManager` | Background upgrade of a cached stream to higher quality when available | Decision logic from `QualityUpgrade.kt`/`StreamChoice.kt` ported into `shared` (pure logic); the re-fetch/re-cache call goes through `native-core`'s `DiskCache`. |
| `WidgetStatePublisher` | Publish playback state for the WidgetKit extension (§9) | On every relevant state change, write the `MediaWidgetSnapshot`-equivalent (id/title/artist/artwork/playing/prev-next availability — *intended ready-to-play* semantics, deliberately no position) plus a size-capped artwork file into the App Group container, then `WidgetCenter.shared.reloadTimelines`. Equivalent of upstream's `publishWidgetState`. |

**macOS polish informed by Keet, explicitly deferred past v1:** Keet ships two macOS-only audiophile features worth knowing about but not building now — "hog mode" (exclusive CoreAudio device access for bit-perfect output) and automatic output sample-rate switching to match the source. If either is wanted later, it belongs in this Swift/CoreAudio layer, not in `native-core`. Likewise Keet's ReplayGain loudness normalization is a candidate later addition that would improve crossfade consistency between tracks of differing loudness.

### 3.3 Spatial Audio — full port, not deferred

**Correction to an earlier draft of this spec:** upstream has no Dolby Atmos integration — there is no `DolbyAtmos.kt` anywhere in the upstream tree (verified). The actual feature is `playback/SpatialAudioProcessor.kt`, a custom Media3 `BaseAudioProcessor` implementing mid/side stereo widening plus a delayed, low-passed crossfeed (Virtualizer-inspired), with an `enabled` toggle. That is what gets ported here, fully, plus one Apple-only enhancement upstream cannot have (head tracking).

**What upstream does (port this exactly):**
- Pure DSP on stereo PCM: `mid = (L+R)/2`; widened `side = (L−R)/2 × widthGain`; opposite-channel audio delayed and one-pole-lowpassed, blended back via `crossfeedGain`; final `outputGain` and clamp-to-short. Tuning constants (`widthGain`, `outputGain`, `crossfeedGain`, `lowpassCoeff`) are private in upstream — copy the values verbatim, do not re-tune by ear.
- `enabled` toggle; when disabled the processor passes audio through unchanged. Keep that semantic exactly — disabled must be sample-identical passthrough.
- Upstream gates on 16-bit stereo only because Media3's sink is 16-bit; `native-core` decodes to float, so implement the math in f32 and drop the encoding gate (keep stereo-only and the clamp behavior).
- `PlaybackService.kt` wires **two** instances (`spatialAudioProcessorA`/`B`), one per ExoPlayer (main + spare crossfade player) — widening runs per-stream, pre-mix. Mirror that: apply `SpatialRenderer` per decode stream, before the §3.1 `Mixer` blends them, so crossfeed filter state stays per-track exactly as upstream's does during crossfades.

**Where it lives:** `native-core/src/spatial/` — a small DSP stage wrapping each source signal before mixing (if the milestone-4 gate picks oddio, this is a custom `Signal` wrapper ahead of the `Mixer`; hand-rolled path, a per-stream stage ahead of the blend). Toggle reaches it through the UniFFI surface (`setSpatialEnabled`), with the user-facing toggle placed wherever upstream surfaces it — grep upstream `ui/` and `data/settings/AppSettings.kt` for `SpatialAudioProcessor`/spatial settings keys and mirror the placement in the matching SwiftUI screen (§5). This stage also future-proofs the Android reunification: the same Rust DSP replaces the Media3 processor there.

**Apple-only enhancement — head tracking (the part upstream can't have):** on iOS with supported headphones (AirPods Pro / Max / AirPods 3 / Beats Fit Pro), `CMHeadphoneMotionManager` (CoreMotion) exposes head attitude; check `isDeviceMotionAvailable`, then `startDeviceMotionUpdates` and feed the head yaw/quaternion into `native-core` so the widened image anchors to the device rather than rotating with the head. Put this in `AppleApp/Sources/SpatialAudio/` as a thin `HeadTracker` feeding a UniFFI `updateHeadRotation`-style call. Design it as an optional input: head tracking unavailable (unsupported headphones, or **macOS — `CMHeadphoneMotionManager` is iOS/watchOS/Catalyst-only, so desktop macOS gets spatial-but-fixed**) must fall back silently to upstream's fixed widening. Do not attempt Atmos/AC-4 bitstream passthrough — YouTube Music streams are stereo; our DSP *is* the spatial feature, and the app should not opt into `AVAudioSession` multichannel spatial rendering (that's for multichannel content and would only fight the in-pipeline effect).

**Validation:**
- DSP parity test (this is cheap — no ONNX involved): feed identical stereo PCM through upstream's `SpatialAudioProcessor` (a JVM unit test) and the Rust `SpatialRenderer`, compare outputs within tolerance for f32-vs-int16 rounding; also assert sample-identical passthrough when disabled.
- Crossfade-with-widening test: transitions with spatial enabled must not glitch or double-process (two per-stream instances active during a transition, matching upstream).
- Head-tracking smoke test on supported AirPods: image stays anchored when turning the head; verify graceful fallback on unsupported headphones and on macOS.
- Toggle UX parity with upstream (same screen, same persistence).

### 3.4 Validation
- Format coverage test (do this **first**, before building the mixer): decode a representative sample of real YouTube Music stream formats (check what `StreamResolver`/`PlayerClient` actually returns — likely Opus/WebM and AAC/M4A containers) through `symphonia` in isolation and confirm clean decode. If a format is unsupported or buggy in `symphonia`, resolve that before investing in the mixer built on top of it.
- Mixer foundation evaluation (alongside the format spike, before building §3.1 `Mixer`): prototype oddio driving a `cpal` stream — two simultaneous sources, sample-accurate scheduled start of the next track at the current one's end, and a crossfade executed via `MixerControl` gain changes from the control thread. Go/no-go criteria: correct gapless timing under load, clean gain ramps without clicks, and an acceptable judgment on oddio's maintenance state (last release 2023-10 — decide whether to pin/vendor it). On no-go, fall back to the hand-rolled sample blending already scoped in §3.1; nothing downstream changes either way.
- Gapless test: back-to-back playback of two tracks with zero perceptible gap or click, verified against at least one variable-bitrate source.
- Crossfade test: transition duration and curve match what `TransitionPlanner`'s test fixtures (if present in `app/src/test/QueueSectionsTest.kt` / similar) expect; transition filtering behaves per §3.5 (bass hand-off during the window, cutoff glides that settle).
- Backgrounding test: playback continues correctly with lock-screen controls functional after app is backgrounded (iOS) / when app loses focus (macOS) — this exercises the Swift↔Rust interruption-handling seam specifically, since it's new relative to the all-Swift design.

### 3.5 Transition Filtering — full port of `TransitionFilterProcessor.kt`

Upstream's *second* Media3 `AudioProcessor`, wired alongside the spatial one in `buildPlayer`, is what makes Automix transitions more than a gain blend. `CrossfadeController` re-aims a low-pass/high-pass pair on every fade tick (30 ms) so that the low end belongs to exactly one track at a time (bass hand-off at a planned swap point) and large tempo gaps are masked by closing the low-pass over the outgoing track. Gain-only blending cannot fix two basslines or two unrelated tempi at once — this DSP is the fix, and it ports to Rust for the same reasons as §3.3.

**What upstream does (port exactly):**
- Topology-preserving (trapezoidal-integrator) state-variable filter; two cascaded second-order sections per filter for a 24 dB/octave Butterworth response (`STAGES = 2`, `BUTTERWORTH_Q = [0.54120, 1.30656]`).
- Cutoffs are *targets*, not values — the real cutoff chases its target geometrically (perception of cutoff is logarithmic); `tan` is evaluated once per sub-block, not per sample; the whole thing degenerates to a buffer copy when both cutoffs are parked.
- Copy constants verbatim: `OPEN_HZ = 20_000`, `OFF_HZ = 20`, `MAX_HIGH_PASS_HZ = 2_000`, `GLIDE_FRAMES = 64`, `GLIDE_RATE = 0.05`, `SETTLED_HZ = 1`, `MAX_CUTOFF_FRACTION = 0.45`.
- Surface: `setCutoffs(lowPassHz, highPassHz)` and `open()`; upstream's `TransitionFilters` routing exposes `incoming`/`outgoing` instances plus a no-op `None` — keep that shape (one filter instance per stream, driven by the transition controller).
- The 16-bit PCM gate is a Media3-sink artifact; as in §3.3, implement in f32 and keep the clamp behavior.

**Placement:** `native-core/src/transition_filter/` — per-stream stage alongside `SpatialRenderer`, driven by the crossfade execution loop inside the `Mixer` (§3.1), which owns the re-aim cadence now that `CrossfadeController`'s capability is reimplemented in Rust. Preserve upstream's per-stream processor ordering relative to the spatial stage — check the order in upstream's `silenceSkippingRenderers(spatial, filter)` and mirror it exactly.

**Validation:** the same sample-comparison harness as §3.3 (identical PCM through upstream's JVM implementation and the Rust port, within f32-vs-int16 tolerance), specifically covering: parked state is an exact buffer copy, geometric glide trajectory on a cutoff step, and 24 dB/octave Butterworth response at fixed cutoffs. End-to-end: a bass-heavy transition hands off the low end with no double-bass audibility during the crossfade window.

---

## 4. Downloads & Metadata Tagging

`download/FlacTagger.kt`, `Mp4Tagger.kt`, `WebmTagger.kt`, `MediaTagger.kt` are built on Android's `MediaMuxer` — no direct port possible.

- Use the `lofty` crate (pure Rust, actively maintained, covers FLAC/MP4/Opus/WebM tagging) inside `native-core` rather than a separate TagLib C++ bridge — this avoids adding a *third* native toolchain (C++) alongside Kotlin/Native and Rust, and keeps tagging in the same crate and behind the same UniFFI boundary as decode and analysis. Verify `lofty`'s WebM/Opus write support specifically before committing (read support is generally more complete than write support across tagging libraries).
- If `lofty`'s container coverage has gaps, fall back to TagLib via its own small cinterop bridge as a last resort, kept in `AppleApp/Sources/Tagging/` — but attempt the Rust-only path first, since it removes a whole toolchain rather than adding one.
- Port `download/DownloadService.kt`, `DownloadStore.kt`, `Downloader.kt`, `Downloads.kt` **decision/state logic** (what to download, queue management, progress tracking) into `shared` — only the final "write these tags to this file" call goes through `native-core`.

---

## 5. UI — SwiftUI, screen-by-screen mapping

All files in `ui/screens/*.kt` and `ui/components/*.kt` are Compose — full rewrites, no logic to port (any state derivation belongs in `MainViewModel.kt`'s portable pieces, see below). Location: `AppleApp/Sources/UI/`.

**Navigation, tabs, chrome, icons, and deployment targets are governed by `bitchord-apple-ui-spec.md`** (this folder) — four canonical tabs (Home, Explore, Library, Search) in one `.sidebarAdaptable` `TabView`, Apple Music-style playback chrome per platform, upstream icons exported as template assets, app floor raised to iOS 18 / macOS 15. This section remains authoritative for per-screen view naming.

| Upstream Compose screen | SwiftUI equivalent | Notes |
|---|---|---|
| `HomeScreen.kt` | `HomeView.swift` | |
| `SearchScreen.kt` | `SearchView.swift` | |
| `LibraryScreen.kt` | `LibraryView.swift` | Includes `LibraryGridPage` — the full-screen "see all" grid the library shelves open into. |
| `LocalMusicScreen.kt` | `LocalMusicView.swift` | Local file scanning — use `MediaLibrary`/manual directory scan on macOS, `MPMediaLibrary` is iOS-only and permission-gated; for macOS, scan a user-selected folder via `NSOpenPanel` + security-scoped bookmarks. |
| `DetailScreen.kt` | `DetailView.swift` | |
| `HistoryScreen.kt` | `HistoryView.swift` | Listening history page (opened from settings/player menu). |
| `SourcesScreen.kt` | `SourcesView.swift` | |
| `DiscordScreen.kt`, `auth/DiscordLoginScreen.kt` | `DiscordSettingsView.swift`, `DiscordLoginView.swift` | Discord OAuth flow — use `ASWebAuthenticationSession` on Apple, replacing whatever Android custom-tabs/WebView flow upstream uses. |
| `auth/YtMusicLoginScreen.kt` | `YtMusicLoginView.swift` | Same OAuth pattern via `ASWebAuthenticationSession`. |
| `SpotifyCanvasAuthScreen.kt` | `SpotifyCanvasAuthView.swift` | Spotify OAuth for the canvas-artwork source — same `ASWebAuthenticationSession` pattern. |
| `ui/replay/*.kt` (`ReplayScreen`, `ReplayCard`, `ReplayModel`, `ReplayPoster`, `ReplayStories`, `ReplayShareSheet`) | `ReplayView.swift` + supporting views | Year-in-review package (stats, story pages, shareable poster/images). All rendering — rebase on SwiftUI `Canvas`/`ImageRenderer` for the poster and story exports; the model logic (`ReplayModel`) is pure Kotlin and belongs in `shared`. |
| `AccountAndScrobblingScreen.kt` | `AccountSettingsView.swift` | |
| `SettingsSheet.kt` | `SettingsView.swift` | |
| `ui/player/NowPlayingScreen.kt`, `CanvasArtworkPlayer.kt`, `MeshGradient.kt`, `ThinSlider.kt` | `NowPlayingView.swift` + supporting views | `MeshGradient.kt`'s animated gradient background has a near-direct SwiftUI equivalent in `MeshGradient` (SwiftUI, iOS 18+/macOS 15+ native API) — check minimum OS target before relying on it; fall back to a custom `Canvas`-based gradient if targeting earlier OS versions. |
| `ui/components/*` (MiniPlayer, FloatingBottomBar, FrostedTopBar, TopFadeBlur, BottomFadeScrim, ArtworkBackdrop, PlaylistPickerSheet, SongActionsSheet, BrowseActionsSheet, DownloadManagerSheet, LyricsSourcesDialog, AppLanguageDialog, UpdateAvailableDialog, AccountAlerts, Skeletons, Common) | One SwiftUI view per file, same names minus `.kt` | Frosted/blur effects → `.background(.ultraThinMaterial)` or `NSVisualEffectView` wrapper on macOS. |
| `ui/haptics/Haptics.kt` | Haptics helper in Swift | Named haptic events (`Select`, `Tick`, …) → `UIImpactFeedbackGenerator`/`sensoryFeedback` on iOS; no-op fallback on macOS. |
| `ui/ForegroundState.kt` | Scene-phase handling | App foreground/background observation — `\.scenePhase` in SwiftUI. |
| `ui/theme/Theme.kt`, `ArtworkPalette.kt` | `Theme.swift`, `ArtworkPalette.swift` | Color-from-artwork extraction logic (palette generation) is a pure algorithm — port the *algorithm* into `shared` as common Kotlin if it doesn't depend on Android's `Palette` library; if it does depend on `androidx.palette`, reimplement using a Swift color-quantization approach (e.g. k-means on downsampled pixel data) instead of porting. |
| `ui/icons/BitChordIcons.kt` | Upstream-first: export each glyph's path data to SVG → asset-catalog template images (UI spec §6); SF Symbols only for the documented exceptions (transport glyphs, back chevron, share) | |
| `MainViewModel.kt` | Split: portable state-derivation logic → `shared` as a common `StateFlow`-based ViewModel-equivalent (exposed to Swift via KMP-NativeCoroutines); platform glue (navigation, lifecycle) → native Swift `@Observable` view models per screen |

---

## 6. Discord Rich Presence — mostly portable, one native seam

`com/my/kizzy/*` (gateway + RPC) is portable per §1.2. The one native piece: image asset upload/caching for RPC (`ArtworkCache.kt`, `RpcImage.kt`) may depend on Android bitmap APIs for resizing — if so, keep the HTTP/protocol logic in `shared` and add an `expect fun resizeImage(data: ByteArray, maxDim: Int): ByteArray` with a Core Graphics `actual` implementation.

---

## 7. Build & Tooling Requirements

| Tool | Purpose | Version constraint |
|---|---|---|
| Kotlin | KMP compiler | Use a version with stable Kotlin/Native Apple targets (verify current stable at implementation time — do not assume a specific version without checking) |
| Xcode | Build SwiftUI app; provides the Apple toolchain Kotlin/Native needs for framework linking, plus `xcodebuild -create-xcframework` | Latest stable |
| xcodegen | Generate `.xcodeproj` from `project.yml` (mirrors amgi's approach — keeps app target config out of raw pbxproj diffs) | latest |
| Rust + rustup | `native-core` toolchain | Latest stable; add targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin` via `rustup target add` |
| `uniffi-rs` (+ `uniffi-bindgen`) | Generate Swift **and** Kotlin bindings from `native-core`'s `#[uniffi::export]` surface — replaces the earlier cbindgen + hand-written Kotlin/Native cinterop plan | latest stable |
| `cargo-swift` | Optional UniFFI-based cargo plugin that packages generated Swift bindings + static libs into an SPM package (alternative to manual `uniffi-bindgen` + `xcodebuild -create-xcframework`) | latest — actively maintained at time of writing |
| `oddio` | Candidate mixer layer on top of `cpal` (§3.1) — **adoption gated by the §8 milestone-4 spike**; assess API fit and maintenance state first (last release 2023-10) | 0.7.x; MIT OR Apache-2.0 |
| Keet (`amsdias/Keet`) | Browsable reference only — proves symphonia+SIMD decode of AAC/M4A/ALAC/AIFF and gapless/equal-power-crossfade patterns; never built or linked | upstream at time of implementation |
| `symphonia` | Audio decode (FLAC/MP3/AAC/Opus/Vorbis) inside `native-core` | latest; confirm AAC and WebM/Opus demux coverage against real stream formats early (§3.4) |
| `cpal` | Cross-platform audio output (CoreAudio on Apple) inside `native-core` | latest |
| `ort` | Rust ONNX Runtime binding, runs `beat_this_int8.onnx` / `vocals_umxhq_int8.onnx` | Match the opset version the upstream models were exported with — check upstream's Gradle ONNX Runtime dependency version for the reference opset |
| `lofty` | Metadata tagging (FLAC/MP4/Opus/WebM) inside `native-core` | latest; verify write support for WebM/Opus before committing, see §4 |
| KMP-NativeCoroutines | Bridge Kotlin `suspend`/`Flow` to Swift `async`/Combine | latest |
| multiplatform-settings | Cross-platform key-value storage | latest |
| SQLDelight (if local DB needed) | Portable SQL schema/queries | latest, only if upstream Room usage confirmed |

---

## 8. Build Sequence / Milestones

Execute in this order — each milestone should be independently testable before proceeding.

1. **Scaffold**: repo layout, submodule added, `shared` module created (empty, compiles for all three Apple targets), `native-core` crate created (empty, cross-compiles for all three Apple targets and produces a linkable static lib), `AppleApp` skeleton (empty SwiftUI app, links both the empty `BitChordShared.xcframework` and an empty `NativeCoreFFI.xcframework` successfully — the Rust static lib ships as the UniFFI FFI framework itself, so the bundle/module name is `NativeCoreFFI`, not `NativeCore`). *Gate: both frameworks build and link into a "Hello World" SwiftUI app.*
2. **Networking core**: port `Http.kt` → Ktor, port `data/innertube/*`. *Gate: can resolve a real YouTube Music search query and print results from a Swift command-line test harness calling into `shared`.*
3. **Sources + module system**: port `data/sources/*`, implement `QuickJsExecutor` actual via JavaScriptCore. *Gate: a module script loads and executes via JavaScriptCore, returns expected results matching upstream's Android QuickJS output for the same script/input.*
4. **Format coverage + mixer-foundation spike**: decode real, current YouTube Music stream formats through `symphonia` in isolation, no mixer yet; in parallel, run the oddio evaluation from §3.4 (two-source gapless/crossfade prototype over a `cpal` stream). *Gate: clean decode of the actual container/codec combinations `StreamResolver` returns — resolve any `symphonia` format gaps before proceeding to milestone 6 — plus a documented oddio go/no-go decision (hand-rolled mixing is the scoped fallback, so neither outcome blocks the sequence).*
5. **Native core — analyzer**: Rust reimplementation of the DSP logic, `ort`-based ONNX inference, UniFFI binding generation (Swift + Kotlin) and wiring of the §1.3 `actual`s against the generated Kotlin API. *Gate: numeric parity with upstream C++/JNI path on a fixed test track (§2 validation).*
6. **Native core — playback v1**: `StreamingReader` + `Decoder` + basic single-track output via `cpal` (no crossfade yet). Swift-side `NowPlayingController`, `AudioSessionManager` wired to it. *Gate: play a resolved stream URL end-to-end with lock-screen controls working.*
7. **Native core — playback v2**: `DiskCache`, gapless + crossfade mixing (oddio or hand-rolled, per the milestone-4 gate), `TransitionFilter` DSP parity (§3.5) driven by the crossfade loop, `QueueBuilder`/`QueueShuffle`/`Autoplay` wiring from `shared`, `SleepTimerController`. *Gate: gapless + crossfade validation per §3.4 and transition-filter parity per §3.5.*
8. **Spatial audio**: port `SpatialAudioProcessor` DSP into `native-core/src/spatial/` (§3.3) with the per-stream placement, UniFFI toggle, and settings persistence — a minimal in-app toggle affordance is acceptable at this stage, with exact screen-placement parity against upstream verified during milestone 12's UI build-out; then the iOS `HeadTracker` spike via `CMHeadphoneMotionManager` (fallback to fixed widening is the graceful default, so head tracking going badly never blocks the milestone). *Gate: DSP numeric parity with upstream on identical PCM and sample-identical passthrough when disabled (§3.3 validation); crossfade-with-widening test clean; toggle functional and persisted.*
9. **Downloads + tagging**: `download/*` decision logic in `shared`, `lofty`-based tagging in `native-core`. *Gate: download a track, verify tags readable by a third-party tool.*
10. **Lyrics + scrobbling + canvas**: port remaining `data/lyrics`, `data/scrobbling`, `data/canvas`. *Gate: lyrics sync display works against a live playback session; a scrobble is confirmed received by Last.fm/ListenBrainz test account.*
11. **Discord RPC**: port gateway/RPC logic, native image resize seam. *Gate: Discord shows live "Now Playing" presence.*
12. **UI build-out**: per `bitchord-apple-ui-spec.md` — navigation shell first (four canonical tabs in one `.sidebarAdaptable` `TabView`, upstream icons), then playback chrome (iOS mini-player / macOS top playback bar), tab content, Now Playing, detail/supporting sheets, polish. Order and gates in that document's §11; screen naming per §5 of this spec.
13. **Widgets (iOS + macOS)**: App Group snapshot publishing (`WidgetStatePublisher` per §3.2), the WidgetKit extension per §9 (square + medium families, artwork pipeline with the no-network/no-native-core constraints, deep link into the full player), and the §9 control-delivery decision-gate spike before building interactive transport. *Gate: §9 validation — snapshot parity with upstream, rendering correct on both platforms and both families, action semantics including the stopped/paused rules, deep link opens the player, and widget controls actually control playback with the app backgrounded.*
14. **Auth flows**: `ASWebAuthenticationSession`-based YT Music + Discord login.
15. **Polish**: theming, artwork palette extraction, icons, animations.

---

## 9. Widgets — WidgetKit extension for iOS and macOS

Upstream ships a home-screen media widget (`widget/MediaWidget.kt`, `MediaWidgetActions.kt`, `MediaWidgetArt.kt`, `MediaWidgetSnapshot.kt`) — square and wide `RemoteViews` layouts, snapshot-driven, with working transport buttons. This section scopes the Apple equivalent in full: same state, same look, same action rules, on both platforms.

**What upstream does (the parity contract):**

- *Rendering is snapshot-driven.* `MediaWidgetSnapshot` persists in SharedPreferences (`"bitchord_widget"`): track id, title, artist, artwork, playing flag, prev/next availability — deliberately **no position** (the widget shows an *intended ready-to-play* state, not a live progress view), with a last-played-track fallback when nothing is loaded so the widget is never blank after a first play. `publishWidgetState` writes the snapshot on every relevant state change and triggers the RemoteViews update.
- *Two layouts:* square and wide; wide adds the artist and only applies above `WIDE_LAYOUT_MIN_DP` (215 dp). Transport buttons are dimmed, not removed, when unavailable.
- *The artwork is one pre-baked composite* (`MediaWidgetArt`): album cover edge-to-edge with its bottom dissolving into a multi-level, accelerating blur plus a dark scrim under the transport band — a CPU re-implementation of the app's `BottomFadeBlur` look, necessary only because `RemoteViews` cannot blur at runtime. Two ideas in it are worth carrying over regardless of platform: artwork is fetched at one of the app's *existing* cached sizes (`ROW_ART_PX`…`HEADER_ART_PX`) so the widget shares the app's disk cache instead of pulling its own copy over the wire, and finished composites are LRU-cached per track+size so a play/pause tap never re-derives the image.
- *Action semantics* (`MediaWidgetActions`, broadcast intents): toggle, next, previous. Rules to preserve verbatim: binding/updating the widget must never start playback; **toggle may start playback from stopped** (resuming the last queue); **next/previous must not start playback from paused**.
- *Tapping the artwork opens the full player* — the sole upstream purpose of `PlayerDeepLink.kt` (§1.2): a one-shot pending state, set by the widget tap, consumed once by the UI.

**Apple architecture:**

| Piece | Approach |
|---|---|
| Extension | WidgetKit extension (`AppleApp/Widget/` target added in `project.yml`, shared App Group entitlement) as a SwiftUI `Widget` + `TimelineProvider`; one codebase serves iOS and macOS. Families: `systemSmall` ≈ upstream square, `systemMedium` ≈ upstream wide (artist always shown — medium is always wider than the wide threshold, so no width gate is needed). Interactive transport requires iOS 17 / macOS 14 (`Button(intent:)` + App Intents); the app floor is iOS 18 / macOS 15 (UI spec §9), so this minimum is always met — the tap-to-open degradation case no longer applies. |
| State | The extension never links `native-core` and never touches the network — it is a read-only consumer of the App Group container. `WidgetStatePublisher` (§3.2) writes the snapshot with the same field set and semantics (ready-to-play flag, last-played fallback) into `UserDefaults(suiteName:)`, then `WidgetCenter.shared.reloadTimelines(ofKind:)` — that replaces upstream's broadcast update trigger. The timeline itself is a single entry: the publisher pushes freshness, no polling, no future entries. |
| Artwork | `MediaWidgetArt`'s CPU blur pyramid is a `RemoteViews` workaround — do not port it. WidgetKit renders real SwiftUI, so the widget draws the artwork file from the App Group and applies the bottom fade + scrim as view overlays (a gradient-masked blur reproduces upstream's accelerating ramp; upstream's `BLUR_SIGMAS`/`STOPS`/`SCRIM_SCALE` are the tuning reference, and system corner rounding comes free). What *does* carry over: the publisher writes artwork at a size the app already downloaded (the media session's own artwork / the app's image-cache ladder) so the widget causes no network fetches, one file per track so play/pause updates re-render overlays but never the image, and upstream's dark gradient placeholder when there is no art — run through the same fade/scrim treatment. |
| Controls | One App Intent per upstream action — toggle, next, previous — enforcing the stopped/paused rules above and doing nothing as a side effect of rendering or timeline reloads. How the intents reach the playback engine when the app is not foregrounded is the one unverified piece of this section — decision gate below. |
| Deep link | Tapping the widget (upstream: the artwork tap) → `widgetURL` → app opens → the existing `MusicLink` intake (§1.2) sets the `PlayerDeepLink` one-shot → `NowPlayingView` consumes it exactly once. No second mechanism — the same seam as external link handling. |

**Decision gate — control delivery (spike before building the transport buttons):** widget button intents run out-of-process from the app's UI; the open question is how toggle/next/prev reach the `native-core` engine when the app is not foregrounded. Candidates, in order of preference: (a) the intent triggers background execution in the app's process — cleanest for an audio app whose background-audio session is already configured, if current OS versions allow it (verify `openAppWhenRun = false` semantics for audio apps empirically, do not assume); (b) the intent drives the same `MPRemoteCommandCenter` surface the lock-screen controls use (§3.2) — if a supported route from an intent into the system media path exists, the widget reuses the exact code path lock-screen controls already exercise; (c) guaranteed fallback — `openAppWhenRun = true`, or a deep link carrying the action payload that the app executes at launch: works everywhere but pops the app to the front for a pause tap, degrading the UX. Ship (a) or (b) if verified; ship (c) otherwise and document which one landed. The milestone gate is behavioral either way: a widget pause must actually pause audible playback with the app in the background.

**Validation:**

- Snapshot parity: identical playback state → identical field set in the App Group container vs upstream's SharedPreferences snapshot, including ready-to-play flag semantics and the last-played fallback with an empty queue.
- Rendering: both families on both platforms; artist on medium only; transport dimmed when unavailable; artwork within the extension's memory limits; placeholder gradient when there is no art.
- Freshness: play/pause/track-change/skip reflect in the widget with no polling, on both platforms; a play/pause update must not blink the artwork (upstream's one-shot-update guarantee).
- Action semantics: toggle starts from stopped with the last queue; next/prev do not start from paused; adding or reloading the widget never starts playback.
- Deep link: tap from either family opens the full player at the current/last track; the one-shot is consumed exactly once.
- Control delivery (whichever mechanism wins the gate): with the app backgrounded (iOS) / unfocused (macOS), a widget pause actually pauses audible playback.

---

## 10. Explicit Non-Goals for This Spec

- No attempt to unify the Android app into the same `shared` module in this pass — `shared`'s `androidMain` source set exists as a placeholder only. Reunifying Android onto `shared`/`native-core` (replacing Media3 with the Rust engine, via UniFFI-generated JVM Kotlin bindings from the same crate rather than new JNI glue) is a separate future project, though `native-core`'s design should not preclude it.
- No attempt to maintain a live Gradle dependency on upstream — the submodule is reference-only, confirmed in §0.
- No attempt to unify `native-core`'s build with Gradle — it is built independently via `scripts/build-native-core.sh` (Cargo) and consumed as a prebuilt XCFramework, same pattern as `shared`'s Kotlin/Native XCFramework.
- Legal/ToS posture of the underlying YouTube Music API access is unchanged from upstream and is out of scope for this spec — this port inherits whatever gray-area status the upstream project already has.

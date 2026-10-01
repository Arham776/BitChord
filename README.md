# BitChord for Apple Platforms

An unofficial Apple-platform port of [BitChord](https://github.com/kushagrasinghx/BitChord), the music client originally created by [Kushagra Singh](https://github.com/kushagrasinghx).

This project brings BitChord to macOS, iPhone, and iPad with a SwiftUI interface, shared Kotlin Multiplatform logic, and a Rust audio engine. It is an independent port; it is not affiliated with Google or YouTube.

## Platforms

- **macOS 15 or later**
- **iOS and iPadOS 18 or later**
- **Apple Silicon only.** The configured macOS, iOS device, and iOS Simulator targets are arm64; Intel Macs and Intel iOS simulators are not configured.

The project is source-first. iPhone and iPad users build and sign the app themselves in Xcode. A signed macOS package may be shared separately as a release.

## Features

The current codebase includes:

- YouTube Music search, browsing, and playback, with optional account sign-in.
- Configurable music sources and source modules, local music files, and WebDAV libraries.
- A native playback engine with downloads, queue management, gapless playback, crossfade, equalizer, and audio-route information.
- Lyrics from multiple providers, including word-synced lyrics where a source supplies them.
- Automix transitions with beat analysis. Optional analysis models can be downloaded in the app; Automix retains a fallback when they are not installed.
- Listen Together, which requires a compatible server address supplied by the listener.
- Widgets, Discord Rich Presence, and Last.fm or ListenBrainz scrobbling.
- Apple-platform audio options, including spatial processing and, on macOS, conditional bit-perfect output when the selected DAC and source format allow it.

Features that depend on external services, sources, audio routes, or optional models may behave differently as those dependencies change.

## Build from source

Builds currently require a Mac with Xcode and the Apple SDKs for the deployment targets above. Install these tools and make them available on `PATH`:

- Xcode, including its command-line tools.
- XcodeGen.
- A JDK supported by the Gradle wrapper.
- Rust with `rustup` and the Apple targets used by the native core.
- CMake, needed by the bundled Opus build.

Clone the repository:

```sh
git clone https://github.com/bagumamartin/BitChord.git
cd BitChord
```

The pinned upstream submodule is kept for source comparison and attribution; it is not a build dependency. Initialize it if you want the upstream source locally:

```sh
git submodule update --init --recursive
```

Build the shared framework and native audio framework, generate the Xcode project, and open it:

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-shared-framework.sh
./scripts/build-native-core.sh
xcodegen generate --spec AppleApp/project.yml
open AppleApp/BitChord.xcodeproj
```

In Xcode, select the `BitChord` scheme and choose a Mac, iPhone, iPad, or Apple Silicon Simulator destination. Device builds need a signing identity and provisioning that you control. `AppleApp/project.yml` contains a maintainer-specific `DEVELOPMENT_TEAM`; replace it with your own team before signing. The current entitlements are configured for development; review them, including the app sandbox setting, before preparing a distributed macOS build. The generated frameworks, Swift bindings, and Xcode project are build outputs and are ignored by Git.

`build-shared-framework.sh` builds the Debug framework by default. For a Release shared framework, run:

```sh
CONFIG=release ./scripts/build-shared-framework.sh
```

The native-core script builds Release frameworks for the configured Apple targets. Run both framework scripts again after changing code in `shared/` or `native-core/`.

### Optional Listen Together server

The app does not ship with a hosted Listen Together service. Enter a compatible server in the app, or set `LISTEN_TOGETHER_SERVER` in the environment or in the root `local.properties` file. With neither configured, the listener supplies a server in the app.

### Optional Automix models

Automix works without downloaded models, using its built-in analysis fallback. The app can offer the beat-analysis model and the larger vocal-analysis model separately. The developer helper `scripts/fetch-automix-models.sh` downloads and verifies both models into `AppleApp/Resources/Models/` for local builds.

## External services

BitChord is client software; it does not host or license the music catalogues it can access. It connects to third-party music, lyrics, and account services, whose availability and behavior are outside this project's control. You are responsible for following the terms of services you use and the laws that apply to you.

## Credits and licenses

This is an unofficial port of [BitChord by Kushagra Singh](https://github.com/kushagrasinghx/BitChord). The upstream source is pinned as a Git submodule at [`fe198ac`](https://github.com/kushagrasinghx/BitChord/tree/fe198ac); its source, per-file notices, and license are available in `vendor/bitchord-upstream` when the submodule is initialized. See the upstream repository's [maintainers and contributors](https://github.com/kushagrasinghx/BitChord/blob/fe198ac/MAINTAINERS.md) for upstream attribution.

Some analyzer code was ported from [Orchard](https://github.com/SFG5453/Orchard), by SFG545, through BitChord's Android implementation. The relevant files identify SFG545 and Kushagra Singh and retain their AGPLv3-or-later terms. The audio clarity contour also credits the [LastWave-native](https://github.com/Clash-Projects/LastWave-native) reference in its source and notices. The upstream README credits [binimum/am-lyrics](https://github.com/binimum/am-lyrics) for the Apple-like lyrics animation; that credit is preserved here.

The root project is licensed under the **GNU General Public License v3.0**; see [`LICENSE`](LICENSE). Some files and bundled dependencies carry additional licenses. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), the files in `LICENSES/`, `AppleApp/Resources/AudioLicenses/`, and individual source headers before redistributing or modifying those components.

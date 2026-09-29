# Third-party notices

BitChord's root project is distributed under GPLv3. See [LICENSE](LICENSE). The pinned
Android source submodule at `vendor/bitchord-upstream` carries its own GPLv3 license and
per-file notices.

## Existing Orchard-derived code

Some analyzer files are ported from Orchard under AGPLv3-or-later. Their source headers
identify the affected files and authors. The complete AGPLv3 text is in
[`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt). GPLv3 section 13 permits the combination
with AGPLv3 code and applies AGPL section 13's network-interaction terms to the combined
work. The GPLv3 text is in [LICENSE](LICENSE).

## Native audio dependencies

`native-core/Cargo.lock` pins the Rust dependency graph. A Cargo metadata scan on
2026-09-28 found 282 registry packages with declared SPDX license expressions and none
without a declared license. The direct runtime dependencies include:

| Package | Version | Declared license |
| --- | ---: | --- |
| cpal | 0.18.2 | Apache-2.0 |
| objc2-core-audio, objc2-core-audio-types | 0.3.2 | Zlib OR Apache-2.0 OR MIT; BitChord uses MIT |
| Symphonia | 0.6.1 | MPL-2.0 |
| Symphonia Opus adapter | 0.3.0 | MIT OR Apache-2.0; BitChord uses the MIT option |
| libopus via opusic-sys | 0.7.5 | BSD-3-Clause |
| UniFFI | 0.32.0 | MPL-2.0 |
| ureq, Lofty, rten, crossbeam-channel, rtrb, log, env_logger | pinned in Cargo.lock | MIT, Apache-2.0, or both |

The selected notices are included under [`LICENSES/third-party`](LICENSES/third-party):
Apache-2.0 for CPAL, MIT for the CoreAudio bindings and Opus adapter, and the
BSD-3-Clause Opus notice for the bundled decoder. MPL-2.0 applies to Symphonia and
UniFFI. Symphonia and UniFFI remain MPL-covered files within the GPLv3
larger work; keep their MPL notices and meet the MPL source-form requirements when
distributing. MPL 2.0 section 3.3 permits distribution in a GPLv3 larger work under both
licenses when its secondary-license conditions are met. The Opus adapter builds its
bundled C library through CMake; CMake must be available on `PATH` when building
`native-core`.

The CoreAudio bindings are from the [`objc2` project](https://github.com/madsmtm/objc2).
Its upstream license statement notes that the bindings are derived from Apple SDKs and
that the Xcode SDK license may also apply; see the upstream license text before
redistributing Apple-targeted builds.

## LastWave-native review

LastWave-native's [LICENSE](https://github.com/Clash-Projects/LastWave-native/blob/main/LICENSE)
is GPLv3, which is compatible with BitChord's GPLv3 project license. No LastWave source
files were copied into this change. The new Opus decoder comes from the separately listed
Symphonia adapter and libopus dependencies.

This file records the Rust dependency metadata and the licenses relevant to the current
native-audio changes. It is not a replacement for the source notices, build inputs, or
license inventory belonging to the Android submodule and its platform-specific dependency
graph.

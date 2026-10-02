# Settings, resolver and audio validation — 2026-10-01

## Settings audit

Compared the current upstream SettingsSheet and AppSettings with Apple's SettingsView.
Added the missing Dolby control, unfocused lyric blur and preferred translation
language. Settings uses native navigation: a full screen on iOS, a native Settings
window on macOS, and grouped category pages. Material Rounded and upstream custom
icons render as monochrome template images; the Dolby mark comes from upstream.
The final macOS grouped quality page was checked visually and through accessibility:
Lossless controls, output options and the Dolby control rendered correctly.

The Android OEM Liquid Glass switch has no direct Apple implementation: native
Apple materials follow OS availability. Local-library access uses Apple's folder
permissions rather than Android's all-storage permission. Existing Apple-specific
mixing, source-rate and bit-perfect controls remain functional.

The backup round-trip test exposed broken string splitting in settings import.
Import now parses JSON before applying the recognized, non-secret keys. Lyrics,
translation and Dolby preferences participate in backup and restore.

## Playback and quality

The phone's saved Wi-Fi/mobile values, shared quality policies and effective
playback value all read LOSSLESS. Earlier reporting that Lossless was off was
incorrect. Enabled sources and requested quality are distinct. The phone currently
has YouTube enabled; a quality preference cannot turn a lossy YouTube rendition
into FLAC. Actual decoded format remains visible in Audio Pipeline.

- Physical iPhone 15 Pro Max: ten real tracks, Next every four seconds, three Back
  selections, then return to the first track. Every selection/playback check passed.
  Repeated successfully after the final build/install.
  See `iphone-jsc-navigation-2026-10-01.json`.
- That run exercised real VISIONOS media rejection and recovered through the
  maintained WEB_REMIX proof-token/cipher path. The latter supplied a 291 kbps
  stream. EJS full-player parsing took 2356 ms on the phone; prepared programs are
  reused by the app-owned runtime.
- Strict macOS resolver check: five requested tracks, five served 64 KiB audio
  windows, approximately 0.5 seconds each. No refusals were skipped in this run.
- Native decoder: real PCM and ALAC both decoded as 24-bit / 96 kHz / two channels.
- Served-URL refusal/recovery: two successive resolutions of the same track served
  real audio; the fresh resolution after injected refusal completed in 0.2 seconds.
- Shared tests: 843 passed, including Settings backup round-trip and Dolby
  capability/credential guards. InnerTubeX native tests: 259 passed.
- Sign-in: 90 checks; accounts: 35 checks. HTTP origin/redirect/cookie fixture passed.
- iOS Debug/device and macOS Release builds passed.
- Fresh page loading, in-flight coalescing, obsolete account rejection, transport
  submission ordering and source-document decoding checks passed.

JavaScriptCore now runs upstream's EJS on a dedicated 4 MiB-stack thread. This
replaces the Apple QuickJS execution adapter that crashed on iOS worker stacks.
Token bindings match upstream: visitor-bound PLAYER token, video-bound GVS token.
A served-URL refusal evicts the URL without immediately excluding its entire
profile; repeatedly rejected fresh URLs still trigger the alternate-client path.

## Dolby

Apple's public Atmos HLS sample was decoded by AVFoundation as E-AC-3/JOC, 48 kHz,
six source channels. The standalone renderer passed real progress, stable pause,
resume, seek, stop and credential-rejection checks. The physical iPhone queue
passed playback, pause, resume, Next and Back; see
`iphone-dolby-queue-2026-10-01.json`.

The native stereo engine remains the default. Supported Dolby sources use Apple's
renderer, with generation/identity guards on callbacks and no native DSP/blend
arming. The source codec does not establish that the current system route is
rendering Atmos; system spatial state remains separately reported.

Dolby sources carrying request headers remain ineligible for the Apple renderer.
No account headers are passed to AVFoundation's unrestricted redirect transport.
Header-free HTTPS and local Dolby files are supported; TrueHD remains unsupported.

## Limits

A deliberately forced alternate-client test on macOS returned HTTP 403 even though
web tokens were minted and cipher tasks completed. The physical iPhone's genuine
alternate-client recovery passed. These results do not establish universal provider
availability. Release launch timing against the original build was not measured.
The AirPods route was observed during device tests; Siri, every switching scenario
and every hearing-accessibility configuration were not exhaustively verified.

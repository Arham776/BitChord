# iOS 27 Now Playing device findings

Observed on 2026-09-30, iPhone 15 Pro Max, iOS 27.0.1 (24A446).

## Current outcome

The application lifecycle and transport-delivery fixes are implemented, but
reliable system prominence while mixing is **not solved** on this device.
The final audio policy honors `mix_with_other_audio` in every application state;
no foreground-exclusive fallback is applied implicitly.

The final iOS and macOS builds and `check-now-playing.sh` / `check-transport.sh`
passed. Native framework and Swift bindings were regenerated to accommodate the
parallel audio-quality work. These build/check results do not establish native
prominence under mixing or complete the outstanding physical transport checks.

BitChord now registers its representation after successful activation and a
paused engine load, before releasing audio to the callback. Stop clears the old
representation and starts a new identity so a pending framework call cannot
observe the next playback's metadata or deliver commands for it. Native Play
while already playing refreshes the actual snapshot and requests focus, and
foreground-inactive state (including Control Center) counts as foreground.
The session remains stable through ordinary pauses and track changes.

## Verified transport delivery with exclusive audio

At 08:09:23, the revised startup path activated with `options=0`, registered
before `engine.play`, and iOS read the enabled command list. Application
publication completed with both primary flags true, without a takeover error.
Native Pause at 08:09:28 reached BitChord, followed by deactivation. Native Play
at 08:09:30 reached BitChord and successfully reactivated/resumed playback.

This confirms actual native command delivery for that sequence. It does not
establish all-surface reliability, seeking/accessory coverage, or coexistence.

## Controlled mixing retest

With the same registration ordering and `.mixWithOthers` (`options=1`),
activation and application publication succeeded but system promotion again
threw `internalFailure`. Fresh play, track changes and foreground return did not
grant system-primary status. Native Play commands arrived while the engine was
already playing; native Pause delivery was not observed in this sequence.

## Independent AVAudioPlayer reproduction

The [standalone reproduction](NowPlayingMixingRepro/README.md) uses a real audible
local PCM tone, `AVAudioPlayer`, `.playback` + `.default` + `.mixWithOthers`, and
only the NowPlaying framework. It excludes BitChord's engine, shared library,
queue, artwork and legacy MediaPlayer integration.

Two cold tests reproduced the failure:

- At 08:25:19, activation succeeded with `options=1` and `otherAudio=1`.
- At 08:30:20, after stopping BitChord, activation succeeded with `options=1`
  and `otherAudio=0`.
- In both tests, `eligible=true` and `applicationPrimary=true`, then
  `requestToBecomeSystemPrimary()` threw `MediaSessionError.internalFailure`
  with `systemPrimary=false`.

The [sanitized log](NowPlayingMixingRepro/device-results.log) and
[captured probe screen](NowPlayingMixingRepro/device-probe-result.png) are saved
beside the reproduction source. This establishes the same public-API failure
outside BitChord, including without competing playback. It does not prove that
every supported iOS configuration or OS build has the same restriction.

At 09:09:40, the same probe with `GenericContent` instead of `MusicContent`
activated successfully with `options=1`, `otherAudio=1` and published with
`applicationPrimary=true`. Both the active-foreground entry request and a
request 300 ms after publication threw `internalFailure`; `systemPrimary`
remained false. Both requests logged `appState=0` (active). The result therefore
also occurs with Apple's example content type and after launch has settled.
This comparison was made with competing audio; the alone tests used
`MusicContent`. The probe was stopped and uninstalled after collecting results.

Apple documents that a system-primary request does not guarantee prominence:
https://developer.apple.com/documentation/nowplaying/mediasession/requesttobecomesystemprimary()

The SDK's `AVAudioSession.h` contract permits no category options with the
long-form route-sharing policy, so that policy cannot be substituted while
retaining `.mixWithOthers`. Repeated requests, metadata refreshes, silent audio
or concurrent MediaPlayer publication are not used to mask this result.

## Earlier attempts

## Always-mix attempt — failed

With `.playback`, `.default` and `.mixWithOthers` (`options=1`):

- Audio activation succeeded and playback was audible.
- With no competing audio, the media session reported `eligible=true` and
  successfully became `applicationPrimary=true`.
- The subsequent foreground system-primary request threw
  `NowPlaying.MediaSessionError.internalFailure` and `systemPrimary` remained
  false. Foreground reentry produced the same result.
- The user confirmed no native Now Playing controls appeared. Repeating with
  competing audio also failed to promote the session.

The captured result separates application publication from system prominence.
It does not establish that a different supported configuration can never work,
but the always-mix replacement regressed the previous working behavior and must
not be considered a successful implementation.

### Temporary policy recovery

The previous foreground-exclusive/background-mix-on-activation policy was
temporarily restored for comparison before the controlled tests above.

- Initial exclusive activation (`options=0`) also received `internalFailure`
  from its immediate system-primary request. The error alone does not prove
  mixing caused an individual rejection.
- During subsequent pause/resume and foreground tests, the recovered session
  reported `applicationPrimary=true` and `systemPrimary=true`.
- A later background activation used `options=1` while both primary flags
  remained true. This is evidence of retaining an already prominent session
  under mixing, not evidence of acquiring prominence while initially mixable.
- Native Pause/Play delivery was subsequently observed as recorded above.

The generation checks, truthful activation failures, stable content IDs and
bounded publication retries remain. These are lifecycle safeguards, not evidence
that simultaneous mixing and native system prominence is solved.

For a platform reproduction, use one audible local `MediaSession` with
`.playback` + `.mixWithOthers`, request application primary after successful
activation, then request system primary while foregrounded. Record eligibility,
both primary flags and exact errors. Compare against explicitly exclusive
playback. Do not publish through MediaPlayer at the same time.

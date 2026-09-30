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

## New user log and documented eligibility constraint

The subsequent supplied device log confirms successful activation with
`options=1` and `otherAudio=false`, including on AirPods and the built-in
speaker. iOS reads the playing snapshot and the enabled play, pause, next,
previous and seek commands. The session is application-primary but never
system-primary; playback, route recovery and foreground requests each report
`prominence failed: internalFailure`. There are no native command deliveries in
this supplied log. The CFPrefs message at launch precedes these successful
publications and does not explain the prominence refusal.

Apple's [WWDC22 eligibility explanation](https://developer.apple.com/videos/play/wwdc2022/110338/?time=382)
states that a Now Playing app must register remote commands and configure its
audio session with a nonmixable category and options. That explanation covers
MediaPlayer; the iOS 27 NowPlaying documentation does not promise an exception
for mixable audio. Our device evidence is consistent with this eligibility
constraint. It is not sufficient to classify the refusal as an iOS defect, or
to claim that moving back to MediaPlayer would fix mixing and native controls.

This is not a claim that both states can never coexist: an already prominent
session retained both primary flags during a later mixed activation in the
earlier comparison. That sequence began with exclusive audio; it does not
meet the uninterrupted-coexistence requirement from a cold start, or establish
reliable command delivery while mixing.

The Xcode 27 public SDK does not expose a local MediaSession method that forces
eligibility beyond the two primary requests already in use.
`AVAudioSession.isNowPlayingCandidate` is explicitly unavailable on iOS and
available only on visionOS. Long-form route policy permits no category options,
and the independent route policy is documented as system-controlled and not
something applications should set directly. RemoteMediaSession represents
playback outside the device and is not an appropriate substitute for BitChord's
local audio. None provides a verified supported exception for this requirement.

The existing Play Alongside Other Apps switch continues to default to enabled.
Its description now explains the native-control tradeoff. The iOS main player
also has a waveform button between Audio Output and Listen Together: highlighted
means mixing enabled, dimmed means exclusive audio priority. Both controls bind
to one observable controller-owned preference and the existing persisted key.
The queue pill and lyrics pane are unchanged. All new preference logic and the
button are compiled only for iOS, including iPadOS; macOS is unaffected.

An explicit change reapplies the audio session during playback, loading, or
an ordinary pause that retains activation.
After successful activation, active playback refreshes its actual position and
requests prominence with `reason=mixing preference changed`. A mode change
while paused never resumes playback or requests takeover. Stopped/inactive
playback waits for the next play. Preference, track-selection and
resume generations prevent stale completions from promoting or pausing newer
playback. No lifecycle event changes the preference or disables mixing
implicitly. The highlighted state describes the preference, not a guarantee of
native control availability.

## Main-player switch verification

The switch build passed the iOS and macOS builds and the existing Now Playing
lifecycle and transport checks. The mixing setter and preference-generation
symbols are present in the iOS PlaybackController object and absent from its
macOS counterpart.

In the installed build on 2026-09-30:

- At 19:17:06, the explicit preference change activated with `options=1` and
  logged `reason=mixing preference changed` with both primary flags true.
- At 19:17:33, the next explicit change activated with `options=0`, again with
  both primary flags true. This verifies live application in both directions;
  the session was already system-primary before these changes.
- Native Next arrived at 19:17:36. Repeated native Pause/Play commands arrived
  in the background between 19:18:00 and 19:18:26; resume activation used
  `options=0` and kept the same session identity.
- A device screenshot at 19:19 showed the native Lock Screen card with
  metadata and previous, pause and next controls. The image is retained only
  in the temporary capture directory because it also contains personal
  notifications.

The user confirmed native controls work, but reported a brief Control Center
Pause/Play button oscillation and a harsh transient on Lock Screen/Island
resume. The captured sequence finished native Play while the snapshot was
still paused, then forced an output rebuild and decoder seek on every resume.

The first follow-up was incorrect: it retained an output based only on its
format after deactivating the session. The user reproduced frozen/looping audio
and paused-card loss. The actual-device PCM/AAC regression harness reproduced
this too: initial audio advanced, but every ordinary resume remained near the
paused position with a full ring and zero callback output peak, despite the
controller reporting `playing`. Build success and policy tests did not detect
this real output failure.

The corrected iOS lifecycle retains activation on ordinary pause. Interruptions,
failed activation, cancelled loads, sleep completion, and stopped/finished
playback still release or invalidate it. Output reuse requires activation to
have remained valid before resume, plus matching hardware format. A previously
inactive output is rebuilt before playback resumes. Native Play waits for the
asynchronous start and rejects stale completion after Pause/Stop/selection.
Rate, position, buffering state and timestamp are one observable snapshot value;
metadata refreshes do not re-anchor unchanged transport state.

The explicit debug launch `--verify-native-resume` exercises the real controller,
RemoteIO and local PCM/AAC decoders with a varying signal. It records stable
pause, advancing/monotonic resume, output peaks, rebuild counts, recovery after
release, rapid cancellation and paused mixing changes. It restores the user's
queue and preferences. It does not automate Control Center or Lock Screen taps.
See `NativeResumeDeviceVerification` for captured measurements and commands.

The final corrected run passed all 59 checks, including 10-second pauses for
both formats, output recovery after release, audible output, rapid cancellation,
paused mode changes, and actual SDK observation dependencies. Baseline and corrected measurements are saved in
`NativeResumeDeviceVerification`. Visual native UI confirmation remains separate
from these output measurements. The existing controlled
command checks additionally cover activation failure and stale cancellation.

Seeking, simultaneous competing audio after switching, iPad layout, and the
full rapid-toggle/loading/pause-during-activation matrix have not been verified
in this physical sequence. These observations do not establish cold
system-primary acquisition while mixing.

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

### Cross-surface transport state follow-up

The supplied 20:51 screen recording shows the app's Play triangle while the
Control Center card still shows Pause. The corresponding corrected-audio build
published a paused snapshot while remaining application and system primary.
At 20:52:12 playback paused in the app; at 20:52:21 the native card delivered
another Pause command despite the already-paused state. Storing the SDK snapshot
directly and removing diagnostic mutations from observed getters did not alone
resolve this native state mismatch. Audio progress checks must not be presented
as proof that card symbols are synchronized.

A state-dependent command availability/toggle experiment delivered native Play
and Pause, but the user confirmed a disabled Control Center button and reversed
Lock Screen symbols. That experiment was removed. Literal Play/Pause command
semantics and always-enabled availability are retained while the cause is
isolated; a toggle workaround must not be described as synchronized UI.

The standalone exclusive `AVAudioPlayer` comparison was then run with
`--state-sync --exclusive`. It automatically paused at 21:16:47 while both
primary flags remained true. The user confirmed both native surfaces showed
Play correctly. This comparison isolates a difference in BitChord's custom
output behavior: its Pause muted the callback and mixer but left RemoteIO
rendering. The iOS-only native change stops/restarts the retained output stream
and preserves the ring.

After installing that change and passing all 59 physical-device checks, the
user confirmed both Control Center and the Lock Screen stayed synchronized,
showed Play after an app pause, and resumed on the first tap. The native logs
showed RemoteIO rendering stopping before the paused snapshot, then restarting
the retained output before native Play completed. These checks used exclusive
playback and AirPods. All 156 native library tests, the Now Playing and transport
checks, and iOS/macOS builds passed. Rendering transport changes are gated to
the Rust iOS target; the macOS audio behavior is unchanged.

For a platform reproduction, use one audible local `MediaSession` with
`.playback` + `.mixWithOthers`, request application primary after successful
activation, then request system primary while foregrounded. Record eligibility,
both primary flags and exact errors. Compare against explicitly exclusive
playback. Do not publish through MediaPlayer at the same time.

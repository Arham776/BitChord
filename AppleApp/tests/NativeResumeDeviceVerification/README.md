# iOS pause/resume regression verification

Captured on 2026-09-30 on iPhone 15 Pro Max, iOS 27.0.1 (24A446), built from
`0b601ce` plus this change. Reports contain only synthetic-fixture output
measurements; they contain no user account or media metadata.

`baseline.json` reproduces the failed implementation: ordinary Pause deactivated
the audio session, and Resume reused its old RemoteIO output whenever the format
matched. Initial PCM and AAC playback advanced, but every resume-progress check
failed. Output stayed near 2 seconds, buffered frames stayed queued, and output
peak was zero despite the controller reporting playing. Two long-pause baseline
checks were affected by additional playback activity; the repeated short-pause
output failures reproduced independently for both formats.

`corrected.json` passes all 59 checks using the real PlaybackController, audio
session, RemoteIO callback, decoder, and NowPlaying representation. It covers:

- PCM and AAC playback with a varying 40-second signal.
- Short pauses and 10-second pauses; stable paused positions.
- Advancing, monotonic resume and nonzero audio callback output.
- No output rebuild/re-seek during ordinary active-session resume.
- Required rebuild and advancing audio after deliberately releasing activation.
- Pause during an unfinished native Play and a fresh Play after cancellation.
- Mixing changes in an active paused session without restarting playback.
- The actual iOS SDK adapter observes coherent Pause/Play snapshots without
  invalidating command availability on position or playback-state updates.

The final report was captured through AirPods after the iOS RemoteIO transport
change. Ordinary Pause stops unit rendering while retaining session activation
and decoded audio. Resume starts the same unit, with no output rebuild or seek.
The original callback-only mute left RemoteIO running and produced stale native
Pause symbols even while the app published a paused snapshot. An independent
exclusive `AVAudioPlayer` probe displayed the correct native Play symbols.

The inactive-session recovery measurement suppresses the resume notification to
other apps, so competing audio cannot resume midway through the controlled test.
Production deactivation continues notifying other apps. Ordinary pause retains
activation and does not send that notification. Real interruptions still release
or invalidate activation and prevent reuse of the interrupted output.

To repeat after building/installing a Debug app:

```sh
xcrun devicectl device process launch --device DEVICE_UDID --console \
  --terminate-existing app.bitchord.BitChord -- --verify-native-resume

xcrun devicectl device copy from --device DEVICE_UDID \
  --domain-type appDataContainer \
  --domain-identifier app.bitchord.BitChord \
  --source Documents/native-resume-verification.json \
  --destination /tmp/native-resume-verification.json
```

Leave transport controls untouched for about a minute. This is an explicit Debug
launch, not a normal startup path. It restores the user's saved queue, volume,
context, mixing preference and Automix setting on completion. Keep the console
capture running until the result is printed; a short global devicectl timeout
would terminate capture before the test finishes.

The test calls the handlers used by native transport. It does not automate taps
in Control Center, Lock Screen, Dynamic Island or accessories. The measurements
prove real output recovery; they do not by themselves prove native button
animation, paused-card retention, seeking, or cold prominence under mixing.
Those require a separate native UI/device check.

That separate check passed for this build: with mixing off, the user confirmed
Control Center and the Lock Screen stayed synchronized after pausing from the
app or a native card, and the first native Play tap resumed audio. Native logs
show the retained RemoteIO unit stopping on Pause and starting on Resume.
This confirmation does not establish cold prominence while mixing.

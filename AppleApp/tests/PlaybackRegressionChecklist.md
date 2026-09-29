# Playback and native Now Playing regression checks

Automated checks:

- `bash scripts/check-transport.sh`: blocked loads, superseded selections,
  queue revisions and automatic handoff invalidation.
- `cargo test --manifest-path native-core/Cargo.toml --lib`: mixer, transitions,
  quality swaps, resampling and stale-source command rejection.
- `bash scripts/check-engine.sh`: real Mac output, muted load/commit,
  pause during concurrent output preparation and stale quality swaps.
- Regenerate native frameworks with `scripts/build-native-core.sh` before
  building the app; the Swift bindings include the source-scoped commands.

Device verification (iOS/iPadOS 27):

1. Play a queue with at least three songs. Lock the device. Native Now Playing
   must show the selected song with next, previous, play/pause and seeking.
2. Pause during initial loading, then wait for the download to finish. It must
   remain silent. Play again, then rapidly next/back/pause. Only the latest
   selection may play; a final pause must remain paused.
3. With mixing enabled, start another audio app. Both apps should keep playing.
   Return to BitChord while its audio plays and verify its native controls.
   Stop the competing app and verify system arbitration while BitChord stays
   in the background. Apple controls which session receives prominence.
4. Repeat next/back/pause from the Lock Screen, Control Center, Dynamic Island
   and headphones. Repeat on iPad (without Dynamic Island).
5. Enable Automix and allow a natural handoff. Only the intended transition may
   overlap. Skip during the blend: the outgoing voices must stop. Pause/resume
   during the blend: neither track may continue during the pause.
6. Change output routes during playback and while paused. A paused track must
   stay paused; a later play must use the new route.
7. Upgrade from the version with custom Live Activities. Any old card should
   disappear; playback must not create an ActivityKit card.

Apple documents application-primary publication separately from foreground-only
system takeover. `requestToBecomeSystemPrimary()` is a request, not a guarantee:
https://developer.apple.com/documentation/nowplaying/mediasession/requesttobecomesystemprimary()

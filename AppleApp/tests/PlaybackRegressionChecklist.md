# Playback and native Now Playing regression checks

Automated checks:

- `bash scripts/check-now-playing.sh`: audio readiness, pause/stop during
  publication or promotion, preparation before engine playback, uncancellable
  requests across resume, superseded successful publication, retained
  sessions, bounded retries, invalidation recovery, content identity and
  foreground-only system takeover.
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
3. First test BitChord alone, including cold play, restored play, pause/resume,
   rapid skipping, locking and returning to the foreground. Verify its native
   metadata, seeking and transport controls. Mixing follows only the listener's
   preference, in both foreground and background. Test another audio app started
   both before and after BitChord; record effective session options at each step.
   Native Pause/Play delivery was observed with exclusive audio. System-primary
   acquisition under mixing still failed on the physical iOS 27.0.1 device,
   including in the standalone AVAudioPlayer reproduction; see
   `NowPlayingDeviceFindings.md` and `NowPlayingMixingRepro/README.md`.
   Stop the competing app and verify system arbitration while BitChord stays
   in the background. Apple controls which session receives prominence.
   Repeat with mixing disabled as an explicitly chosen exclusive-mode control.
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

For missing controls, open the song menu's Debug log. Capture the OS build,
route, mixing setting and reproduction sequence alongside the audio activation
outcome/options and Now Playing eligibility, application-primary and
system-primary status. Publication failure and prominence refusal are separate
log events. Do not treat a passing build or coordinator test as proof that iOS
will grant prominence to a mixable session. If activation succeeds but iOS
rejects publication or prominence, preserve mixing and use these diagnostics
for a reproducible platform issue.

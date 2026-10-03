# Autoplay, Automix and list playback verification

Verified on the host Mac on 2026-10-03. No simulators were launched.

Fresh settings enable Autoplay and Automix. Existing saved on/off values are
preserved. Automix Smart Sequencing takes priority over Shuffle; disabling Smart
Sequencing permits Shuffle or source order. Row selections retain the selected
track and played prefix. A Shuffle hero can pick a random starting track without
discarding earlier list tracks.

List provenance is stored per queue entry, and list origin is saved in the queue
snapshot. Manual additions and dragged list tracks keep their positions ahead of
the recommendation tail. Disabling Shuffle restores only upcoming list slots,
so it cannot resurrect removed tracks or discard later manual additions.

YouTube `next` is fetched for selections, natural advances, repeat laps, manual
queue edits and successful ratings. A response replaces only unplayed Autoplay
entries. Failed requests/ratings retain the tail. Playback, queue-edit and
account generations reject stale replies. Listening affinity/freshness applies
immediately; transition ranking uses a bounded window of available audio on a
serial background worker, without downloading a whole list.

History reporting sends playback starts, periodic watch time and final watch time
to the signed-in YouTube account. Repeats and restarting a playing song receive
separate sessions. Late starts report their own skipped play and cannot attach
to a newer track. Progress after signing in during playback starts reporting for
the active account. YouTube downloads retain their selected song identity for
reporting and recommendations; unrelated local songs are not sent to YouTube.

Passed checks:

- 851 shared Kotlin tests on `macosArm64`, including recommendation deduplication,
  reuse of unplayed suggestions, repeat reporting, late starts and account changes.
- 88 standalone Swift queue/policy/snapshot checks: `scripts/check-queue.sh`.
- Missing, saved-off and saved-on preferences in separate process launches:
  `scripts/check-playback-settings.sh`.
- Download origin/ownership checks: `scripts/check-downloads.sh`.
- Transport submission/race checks: `scripts/check-transport.sh`.
- 20 controller/runtime checks with silent local audio and controlled `next`
  replies: `scripts/check-queue-runtime.sh /path/to/Debug/BitChord.app`.
- Debug macOS application build linked with the rebuilt shared Mac framework.

Generate the Xcode project with `xcodegen generate --spec AppleApp/project.yml`
before building; the queue model and policy are now separate source files.

The history tests exercise the reporting transport with controlled callbacks.
They do not measure how YouTube weights received listening activity. iPhone/iPad
runtime and visual checks remain for physical devices.

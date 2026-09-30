# Download and playback improvements — validation

Implemented on 2026-09-30. The implementation adapts the requested behavior to BitChord's shared Kotlin resolvers, Swift persistence/controller, and Rust mixer; audio files and source timestamps are preserved.

## Behavior

- Downloads use an atomic versioned index under Application Support/BitChord/Downloads. Account-scoped collection owners and individual owners bind to recording/rendition assets. Full pagination succeeds before collection membership changes. Two workers join identical resolved assets; cancellation, metered-network changes, three-attempt retries, and pending-job recovery preserve intent. Native reader leases protect outgoing, incoming, and retiring voices during deletion. Legacy files remain individually owned without invented video provenance; exported copies are independent.
- SponsorBlock requests only `music_offtopic` skips. Manual playback/autoplay default off; Automix always applies regions. Only verified exact-video sources carry timestamps. Native voices keep original source positions and allow explicit seek-back replay. Both immediate fallback and analyzed plans respect excluded windows, including updates to an armed waiting voice.
- Edge trimming defaults off outside Automix. Dry stereo PCM is measured in 10 ms windows using separate channel RMS, a shared maximum peak, 350 ms sustained edges, and 100 ms guards. Unfinished streams have no trailing boundary; complete analysis caches use audio fingerprints and version 1.
- Sleep deadlines use ContinuousClock on a task independent of the UI actor. The final six seconds attenuate temporary output gain without changing user volume. After-song hold blocks queued and armed transitions. Diagnostic history uses an asynchronous writer, five runs, a 2 MiB/run cap, sanitized events, and interrupted-run markers. Reports include the engine/output/route/settings snapshot. PCM capture remains separate and explicit.

## Automated results

- Rust native suite: **154 passed**.
- Shared Kotlin macOS suite: **801 passed**, including concurrent mirror-health snapshots. Two download workers exposed an existing mutable-list race during parallel lyrics sidecars; atomic snapshots fixed the crash.
- `scripts/check-downloads.sh`: ownership overlap, last-owner cleanup with reader reservations, exported-file preservation, legacy migration, deferred deletion across relaunch, rendition quality compatibility, relaunch recovery, cancellation, complete collection refresh versus failure, corrupt-index safety, two-worker scheduling, joining, shared-asset playback lookup, Wi-Fi blocking/resumption/interruption, bounded retries, SponsorBlock parsing, diagnostic redaction/retention/export/clearing.
- `bash scripts/check-transport.sh`: stale loads, queue revisions, and handoff invalidation passed.
- `scripts/check-engine.sh`: **39 passed** against real Mac output.
- Final macOS and iOS Simulator Debug builds passed. The separate iOS validation app also built with signing and ran on an iPhone 15 Pro Max.
- Physical iPhone background check: **7/7 passed** — playback starts, final-six-second fade, cancellation restores gain, deadline pauses output, deadline restores gain, deadline fires in background, and after-song blocks repeat/autoplay/next. The separately identified validation app was removed after collecting its report.

## Limits of the evidence

The live `scripts/check-playback.sh` resolver check obtained no playable streams. Its output includes YouTube sign-in/bot gating and unusable URL responses; this does not establish a successful live download from YouTube.

An optional Apple Music Understanding StructuralFeaturesModel aborted inside MPS on a synthetic tone during one device run. The explicit DEBUG `--verify-sleep` validation path bypasses that GPU model to isolate native mixer/timer behavior. This test guard does not change ordinary playback. The passing background check therefore establishes the native fallback path, not the optional system-model path.

Silence fixtures cover residual noise, quiet single-channel music-like tones, out-of-phase stereo, sustained edges, incomplete recordings, all-silent windows, and malformed/excluded intervals. No human listening audition of a real quiet musical recording is claimed.

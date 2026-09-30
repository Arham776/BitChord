# AAC playback-region seek repair

2026-09-30. The reported session resolved and downloaded AAC audio, activated
the audio output, and opened a voice at a 0.190 s trim boundary. The decoder
reported 0.070 s while its compressed preroll was pending. The region loop
repeated the seek without reading that preroll, stalling audio rendering and
later output-format acknowledgments.

The decoder now reports the next returned source frame, including pending
seek-discard frames. Preroll is still decoded and discarded normally. Head
trimming issues at most one seek before reading, including when a boundary
falls between source samples.

Validation:

- The AAC seek-position regression failed before the fix and passes afterward.
  Requested PCM matches continuous decoding within 1e-6 at 0.190, 0.190001 and
  1.337 s, with source position advancing by the returned frame count.
- 156 native tests passed. Cached and late boundaries on the synthetic AAC
  fixture produce audible PCM, skip the internal 1.0–1.5 s interval, and
  complete with the expected retained duration at a 48 kHz output rate.
- 45 real macOS output checks passed, including six new FFI checks for AAC
  output, playhead advancement and output preparation with cached/late regions.
- Native frameworks rebuilt for macOS, iOS and iOS Simulator.
- macOS and generic iOS Debug app builds passed, including the regular Automix
  icon and removal of the unnecessary `await` warning.

The real-output checks use a synthetic recording. They do not establish a new
physical iPhone/AirPods test or a successful live YouTube playback session.

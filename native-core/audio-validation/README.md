# Audio fidelity repair and Enhanced mode

Implementation and validation record, 2026-09-30. The software changes are in the
working tree; the ongoing Now Playing/session work has been preserved. Native
frameworks and generated Swift/Kotlin bindings were rebuilt together, followed
by all shared Apple frameworks and successful generic macOS and iOS/iPadOS app
builds. This record distinguishes measured results from listening or device
checks still requiring the selected recording and hardware.

## Behavior

**Transparent** is the new neutral playback mode. Ordinary playback bypasses
manual EQ/tone controls, clarity, spatial/head tracking, normalization, and
silence skipping. Channel mapping, necessary sample-rate conversion, application
volume, and explicitly selected pitch-preserving speed remain available.
Automix and crossfade remain independent preferences; actual transition stages
are reported while active. Equal-rate, unity-gain, valid stereo PCM passes
sample-exactly. Out-of-range or non-finite samples require intervention, which
is counted; “Transparent” does not claim an overloaded signal is untouched.

**Enhanced** adds the Lastwave Reference contour: 24 Hz high-pass, 72 Hz bass
lift, 280/750 Hz cuts, 3.4 kHz presence, 10.5 kHz air shelf, high-frequency
exciter, 130 Hz side-channel high-pass, 1.22 width, and 1.04 makeup. The four
presets use Lastwave's Reference/Speaker/Headphone/DAC trims, filter Q values,
wet/dry behavior, and 50 ms activation ramp. The exciter runs at 4× with aligned
wet/dry latency. Manual upstream EQ/tone controls remain available; stronger
upstream spatial widening remains a separate option, off by default.

Stereo-linked protection persists across blocks: 5 ms lookahead, 150 ms release,
4× intersample detection, −0.5 dBTP ceiling, and a conservative reconstruction
margin. Filters retain float headroom. A final finite-value/emergency clamp is
counted. This is intentionally a different protection design from Lastwave;
true-peak compliance is measured on defined independent reconstruction fixtures,
not asserted as a mathematical guarantee for every possible signal.

Normalization is Off/Track/Album. ReplayGain metadata takes precedence over
identified BS.1770/EBU R128 integrated loudness measurements. Completed local
and downloaded files are measured off the playback thread and cached against
the encoded file SHA-256. YouTube's relative loudness is labeled separately and
only attenuates; it is never represented as LUFS. Album uses album ReplayGain
or an explicitly provided album measurement, falling back to Track when neither
exists. Automatic whole-album scanning is not included. Newly created profiles
default to Off; legacy normalization preferences migrate. Existing EQ, spatial,
transition and other preferences remain stored, with clarity activated only
when Enhanced is selected.

Qualified macOS bit-perfect output remains separate. It bypasses processing and
transitions and requires eligible lossless PCM, an exact supported integer
format/rate, and exclusive output qualification. The pipeline shows the actual
qualification failure reason. Transparent alone does not imply hardware
bit-perfect output.

## Correctness and continuity repairs

- Every decoded packet is mapped to internal stereo before leftovers are saved.
  Mono duplicates; multichannel uses positioned, normalized Lo/Ro mapping:
  front L/R weight 1, center and corresponding surround/wide/height weight √½,
  left/right positions retain their side, LFE omitted,
  each output divided by its matrix row's absolute-weight sum. Unsupported
  layouts and rate/layout changes fail explicitly.
- Symphonia remains the supported general decoder. Apple AudioToolbox handles
  HE-AAC/SBR/PS and rejected AAC configurations, using full profile/cookie and
  channel layout information, without silently forcing AAC-LC or stereo.
  Priming/padding and end-of-stream output are handled at actual decoded rates.
  Compressed seeks decode and discard preceding packets: 120 ms for AAC/MP3
  and one second for Opus. The longer Opus history removes the measured quiet
  Matroska/WebM predictor residual while preserving the requested frame.
  This exceeds the 80 ms minimum recommended by [RFC 7845 §4.6](https://www.rfc-editor.org/rfc/rfc7845#section-4.6).
- The reference libopus adapter supports mono/stereo Ogg, Matroska and WebM;
  Opus header gain and pre-skip across packets are applied once. Unsupported
  multichannel Opus mappings fail explicitly. The obsolete resolver Opus filter
  is removed; rendition ranking considers codec tiers within the data ceiling.
- Cache manifests store codec, rendition quality/rate, recording identity,
  source identity, completeness, byte count and hash. Legacy/unqualified cache
  entries are re-resolved. Quality changes do not join an older rendition's
  in-flight stream. Old bytes may remain until eviction, preserving active users.
- One owned stereo streaming libsoxr HQ converter performs rate conversion,
  with exact equal-rate bypass, explicit delay, reset and complete draining.
  Pitch-preserving WSOLA handles selected playback speed separately from SRC.
- Seek, source discontinuities and output changes reset state coherently.
  Stretch, SRC and bounded filter/protection tails are drained at EOF.
- The ring has one-second capacity but starts with a 150 ms prebuffer and
  approximately 250 ms fill target. Starvation increases the target toward one
  second. Commands are serviced between render blocks. PCM frame publication
  and integer callback consumption now preserve complete L/R pairs.
- Output callbacks use preallocated storage and perform no decoding/network
  waits. Volume and underrun recovery ramp smoothly. Generation checks and
  mixer acknowledgments serialize output rebuilds; unchanged formats are reused.
  Actual negotiated Apple output values drive the pipeline; preferred session
  rates are hints, as explained in [Apple QA1631](https://developer.apple.com/library/archive/qa/qa1631/_index.html).

## Reference comparison matrix

References: vendored BitChord `fe198ac0bde052f8b84cfd84b1d271f8f1fcc7b2` and
[Lastwave ec11a43 DSP](https://github.com/Clash-Projects/LastWave-Native/blob/ec11a430fcf6e7f06bbae450e768d48f1d97d161/app/src/main/cpp/DspProcessor.cpp).
The older `docs/audio-parity.md` records the upstream analyzer/Automix audit;
this record supersedes its ordinary playback, normalization and output claims.

| Reference capability | Status and Apple behavior |
| --- | --- |
| Upstream manual EQ/tone and optional spatial | Implemented; retained, with float clipping removed. Bypassed in Transparent. |
| Upstream Automix/crossfade/filter rides | Retained as independent settings; actual active stages reported. Existing transition tests pass. |
| Upstream relative YouTube loudness | Deliberately differs: labeled relative attenuation, separate from ReplayGain/LUFS and Off by default for new profiles. |
| Lastwave Reference clarity and preset trims | Implemented; compared against independently compiled actual C++ processor. |
| Lastwave exciter/saturation | Implementation differs: 4× FIR oversampling and aligned latency reduce aliasing; level-dependent output is intentionally not sample-identical. |
| Lastwave output resampling | Implemented using pinned streaming libsoxr HQ, with bypass/drain/delay accounting. |
| Lastwave persistent protection | Implementation differs: stereo-linked lookahead/true-peak protection replaces per-block gain jumps. |
| Android AAudio/Oboe, Media3 session/routes | Android-specific; CoreAudio/AudioToolbox and AVAudioSession provide Apple behavior. Apple negotiated formats are authoritative. |
| Same-recording listening superiority | Not established. Requires level-matched listening to identical bytes on the relevant outputs. |

## Measured evidence

- **145 native tests pass**, including decoder partitioning/counts, integer
  16/24-bit round trips, Transparent equality, SRC tones/near-Nyquist alias
  gates, stateful protection partition independence, hot-input true peaks,
  normalization calibration, pitch preservation, seeks, mixed-rate output,
  transitions, EOF and stale-operation rejection.
- **Two shared rendition-selection tests pass**, covering Opus eligibility,
  codec-aware ranking and strict data limits.
- **13 codec fixtures**: AAC-LC, HE-AAC, HE-AACv2, Opus Ogg/Matroska/WebM,
  MP3, FLAC, ALAC, WAV, AIFF, eight-channel AAC and six-channel WAV. Pull sizes
  7 and 4096 produce identical samples/counts. HE profiles match Apple float
  reference output exactly. AAC-LC differs by at most 1.2e−7; positioned
  eight-channel AAC by at most 1.1e−8. Lossless fixtures match exactly.
  See `codec-comparison.json` for source hashes, frame counts and provenance.
  The multichannel reference is FFmpeg’s [eight-channel AAC identification sample](https://samples.ffmpeg.org/A-codecs/AAC/8_Channel_ID.m4a).
- **13 compressed seek cases pass**: 0.5-second seeks across AAC-LC, HE-AAC,
  HE-AACv2, Opus Ogg/Matroska/WebM, positioned eight-channel AAC and MP3;
  five-second seeks additionally exercise all three Opus containers,
  eight-channel AAC and MP3 away from the stream start. Pull sizes 7/4096
  produce identical output and exact remaining frame counts. AAC-LC, Opus,
  positioned AAC and MP3 match continuous PCM within 1e−6. HE profiles match
  an independent Apple `ExtAudioFileSeek`/`ExtAudioFileRead` path exactly.
  Apple's own HE seek differs from its continuous decode after restarting
  SBR/PS state; that difference is not evidence of a timing defect in our
  bridge. See `seek-comparison.json` and `apple_seek_reference.c`.
- **176 Lastwave response comparisons**: four presets, two rates, mid/side,
  eleven frequencies. Maximum low-level RMS deviation **0.0864 dB**, below
  the 0.15 dB comparison gate. See `clarity-comparison.json`, including the
  actual C++ revision and Rust DSP source hash.
- **SRC gates pass**: ≤0.05 dB passband deviation through 20 kHz at 44.1↔48 kHz,
  with alias/image products below −100 dBFS on the defined 23/21.5 kHz fixtures.
- Production speed and bounded capture evidence: `pipeline-comparison.json`.
  At 1.25× the 35-second 997 Hz fixture produces 28.0057 seconds at
  996.250 Hz (−1.30 cents, inside the defined ±3-cent gate). Diagnostic
  captures export decoder, voice and protected float WAVs, settings
  history, source hash/completeness, codec/layout, active stages, delay,
  protection counters and build revision. Each stage is limited to 30 seconds.
  Completed-source hashing and buffered WAV export run off the mixer thread,
  so capture completion does not block ring replenishment.

Historical production renders use the same three-second 48 kHz stereo float
source through the actual decoder/mixer from `1859a64` and `8e8e44a`, with
normalization/spatial/transitions off. One over-range transient makes the old
guard change **1,022 samples**, with abrupt gain steps of **±0.375** at the
512-frame boundaries and maximum output difference **0.075 full scale**.
Repaired Transparent matches the pre-guard render exactly, with the two
out-of-range samples explicitly counted as interventions. See
`historical-comparison.json`. This is synthetic regression evidence, not the
selected “Nerve” recording.

The initial 30-minute run failed: **1,268 callback underruns**, one route rebuild,
ending on AirPods Pro, with nearly one CPU core used. Its evidence is retained
in `mac-output-stress-initial.json`. Polyphase FIR interpolation, calculating
only the decimated output phases, and pruning provably redundant lookahead
constraints preserve the tested output samples exactly and substantially reduce
DSP cost. See `optimization-comparison.json`. The optimized **30-minute MacBook Air Speakers run passes**: **zero callback
underruns, zero device xruns, zero rebuilds, no engine errors**, at the actual
44.1 kHz output rate with 48 kHz source conversion. The minimum sampled queue
was 10,752 frames (244 ms). Application gain was zero. Concurrent work included
app/native compilation and **140 complete 1,840-second source loudness
measurements over ten minutes**. No listening claim follows from this muted run.
See `mac-output-stress.json`.

**39 Mac hardware checks pass**, covering live playhead advancement, seek,
pause/resume, negotiated formats, no-op and concurrent output rebuilds,
Transparent/Enhanced normalization behavior and stale quality-swap rejection.
These checks use 1% application volume and were repeated on the final core
`6659a8ee32f7+c567f9a8945a`. The sustained stereo DSP test uses core
`6659a8ee32f7+8f191f5e93ee`. Subsequent changes correct positioned multichannel
folds, compressed seeks and diagnostic export; they do not change the steady
stereo playback/DSP path exercised by the 30-minute run. The final core revision
and test counts are in `software-validation.json`.

The final core also passes a **30-second diagnostic capture during physical
Enhanced playback**: zero underruns/xruns, all three stages reach their exact
30-second limits, start/finish source hashes match, and exporting the WAVs plus
hashing a 706 MB complete source finishes in 2.01 seconds off the playback
worker. See `mac-capture-continuity.json`. Application gain is zero.

## Reproduce

```sh
cargo test --manifest-path native-core/Cargo.toml --lib
cargo build --release --manifest-path native-core/Cargo.toml --examples
python3 scripts/audio-verify/prepare_codecs.py native-core/target/audio-validation-work/codecs
python3 scripts/audio-verify/verify_codecs.py native-core/target/audio-validation-work/codecs --report native-core/audio-validation/codec-comparison.json
python3 scripts/audio-verify/compare_clarity.py LASTWAVE_CHECKOUT native-core/audio-validation/clarity-comparison.json
python3 scripts/audio-verify/verify_seeks.py native-core/target/audio-validation-work/codecs
python3 scripts/audio-verify/verify_pipeline.py
python3 scripts/audio-verify/prepare_history.py
for revision in before after; do
  CARGO_TARGET_DIR=/private/tmp/bitchord-audio-history/target cargo build --offline --release \
    --manifest-path /private/tmp/bitchord-audio-history/$revision/native-core/Cargo.toml \
    --example playback_render
  cp /private/tmp/bitchord-audio-history/target/release/examples/playback_render \
    /private/tmp/bitchord-audio-history/$revision-render
done
python3 scripts/audio-verify/verify_history.py
scripts/check-engine.sh
# Optional physical capture-continuity check, with muted output and a >45-second source:
scripts/audio-verify/check_capture_output.sh LONG_LOCAL_SOURCE native-core/audio-validation/mac-capture-continuity.json
```

Use `playback_render INPUT OUTPUT --mode transparent|enhanced --rate 48000
--chunk 7 --preset reference --wet 1 --speed 1 --start 0.5 --capture DIRECTORY` for production
float output before quantization. Apple codec/reference tests require macOS
codec-service access. Fixture bytes are not redistributed here; hashes identify
the exact inputs. Source dependency notices and relinking instructions are in
`THIRD_PARTY_NOTICES.md` and the bundled `AudioLicenses` resources.

## Remaining device and listening gates

The Mac stress harness exercises actual physical CoreAudio output and Enhanced
DSP with adequate local delivery. Application gain is zero so it provides no
listening evidence. Compiler/DSP load is present; a separate in-app UI/analysis
load test remains necessary. iPhone/iPad speakers, USB/wired DACs, Bluetooth and
AirPods route/interrupt/stall tests need the actual devices. USB integer-format
qualification also requires suitable hardware.

“Nerve” by Victoria Nadine uses the recording BitChord selected; no exact video
ID or local rendition was supplied. During that playback, open Audio Pipeline
and choose **Capture 30 seconds**, covering the distorted passage without a
track transition. The saved directory includes `recording.json` (selected
recording/source identity), `capture.json`, and three float WAVs. Use the same
completed encoded source with an independent decoder, then compare Transparent,
Enhanced, Lastwave and historical renders. Match listening levels within
0.1 dB. Confirm the reported distortion is absent before declaring this gate
complete. The established defects do not prove the cause of that specific song.

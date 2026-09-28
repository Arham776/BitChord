//! WSOLA time-stretch — pitch-preserving tempo change, for the Automix handoff.
//!
//! ## Why this exists
//!
//! The handoff stretch the planner asks for is a *tempo* match: hold two
//! records on one beat grid for the length of a blend. Implemented as a
//! resampling rate change — which is what this engine did, and what ExoPlayer
//! does with `setPlaybackSpeed` — a tempo change is also a pitch change, by
//! construction and by about a hundred times as much: 3 % of tempo is 51
//! cents, a quarter of a semitone. For a speed control that is the expected
//! trade. For a transition it is not, because the stretch is *released* when
//! the blend ends, so the ear hears the pitch bend and then hears it snap back.
//! Apple Music's AutoMix is not accused of that; James Cridland's write-up of it
//! notices "a bit of obvious speed slowing", which is the sound of a tempo ramp
//! — an intended move — rather than of a pitch step.
//!
//! ## The algorithm
//!
//! Waveform-similarity overlap-add. The output is assembled from fixed-length
//! frames of the input, windowed and overlapped at 75 %. At a rate of exactly
//! 1.0 that reconstructs the input; above or below it, the frames are placed
//! closer together or further apart in the input than they are in the output.
//!
//! Placing them naively just resamples — the content of each frame lands at the
//! wrong pitch. What avoids that is the *similarity* step: for each output frame
//! the analysis position is allowed to slide within a small search window, and
//! the offset whose head best continues the previous frame wins. The phase of
//! the waveform is therefore realigned at every hop, so pitch stays where the
//! recording put it and only the timing moves.
//!
//! Two things make that stable rather than merely plausible, and both are easy
//! to get wrong:
//!
//! * **The anchor advances deterministically.** Frame *n* is placed at
//!   `anchor + delta` and the *next* anchor is `anchor + hop * rate` — not
//!   `placed + hop * rate`. `rate` is a playback speed: above 1 the same record
//!   takes less time, which is what a tempo match wants from a slower incoming
//!   track. Advancing from the placement instead lets the search set the rate:
//!   each frame can be up to `SEARCH` samples off its aim, and that error
//!   compounds until the effective ratio is whatever the walk settled on.
//! * **The reference is the previous placement, not the previous anchor.** The
//!   similarity criterion is about continuity with what was actually
//!   synthesised, so the offset that matches the input continuing from where
//!   the last frame really landed is the one to compare against. Bounded and
//!   non-accumulating either way, since `delta` never enters the anchor.
//! * **The hop keeps its fraction.** `hop * rate` is rarely an integer. Rounding
//!   it every hop walks the tempo — half a sample, the same way, thousands of
//!   times — which over a long blend is a flam. The fractional part is carried
//!   and added into the next hop, so the long-term ratio is the rate asked for.
//!
//! ## Stereo
//!
//! One offset is chosen per frame from the mid signal and applied to both
//! channels. Choosing per channel would let L and R slide apart inside one hop
//! and smear the stereo image on anything with reverb in it.
//!
//! ## Latency
//!
//! `frame + search` samples, about 12 ms at 48 kHz — small enough that the
//! blend's own timing is unaffected, and it is bounded rather than growing with
//! stream length, because the anchor only ever moves forward by `hop * rate` per
//! output hop. [`TimeStretch::latency_frames`] reports it and the mixer
//! subtracts it, so a playhead never leads or trails the audio.
//!
//! ## Why flushing matters
//!
//! At a rate of exactly 1.0 the output is sample-identical to the input, so
//! [`TimeStretch::flush`] and then dropping the stage is a seamless handover
//! back to a plain pass-through. That is what lets the mixer retire the
//! stretcher the moment the glide lands on unity, instead of carrying the stage
//! — and its latency — for the rest of the track.

use core::f32::consts::PI;

/// Analysis frame. 512 samples is 10.7 ms at 48 kHz: short enough that a ±5 %
/// stretch smears less than a pitch period of a bass note, long enough that the
/// similarity search has something to correlate.
const FRAME: usize = 512;
/// Synthesis hop. A quarter of the frame is 75 % overlap — the usual WSOLA
/// figure, and the minimum that keeps the Hann window sum flat enough to
/// normalise away.
const HOP: usize = FRAME / 4;
/// How far the analysis position may slide to find a waveform match, in
/// samples either way. Must be well under a pitch period of the content that
/// matters: too wide and the search will happily lock onto a *different* cycle
/// of a low note, which is an octave error wearing a similarity mask.
const SEARCH: isize = 64;
/// Correlation window, in samples. The overlap region is three quarters of the
/// frame; correlating over half of it is enough to identify the waveform and
/// halves the work.
const CORRELATE: usize = FRAME / 2;
/// Divisor floor for the overlap-add normalisation. Only a 0/0 guard: the
/// window is exactly zero at its first sample, and everywhere else the weight
/// is small but real and dividing by it is the accurate reconstruction.
const WEIGHT_FLOOR: f32 = 1.0e-6;

/// WSOLA time-stretcher. Interleaved stereo `f32` in and out.
pub struct TimeStretch {
    window: Vec<f32>,
    /// Input not yet placed, interleaved. `base` is the absolute input index of
    /// `fifo[0]`; placed input is dropped off the front as the anchor advances,
    /// so this stays a frame or two rather than the whole track.
    fifo: Vec<f32>,
    base: usize,
    /// Overlap-add accumulator covering one frame of output, interleaved.
    accum: Vec<f32>,
    /// The window weight actually accumulated at each output sample. Dividing
    /// by this rather than by the theoretical 75 %-overlap sum is what makes
    /// the first and last hops come out at the right level: at the start only
    /// one or two frames have contributed, and a fixed divisor would scale them
    /// by two.
    weight: Vec<f32>,
    /// Placed output, interleaved.
    out: Vec<f32>,
    /// Where the next frame's analysis position *aims*. Advances by
    /// `HOP * rate` input frames per output hop — `rate` is a playback speed —
    /// regardless of where the search placed the last one, so the stretch ratio
    /// is carried here alone.
    anchor: usize,
    /// Fractional input frame owed to the anchor. `HOP * rate` is not an
    /// integer; dropping the fraction every hop walks the tempo.
    anchor_frac: f64,
    /// Where the last frame was actually placed — the similarity reference.
    placed: Option<usize>,
    rate: f64,
    /// Output frames already emitted, and input frames already placed. Their
    /// difference is the stage's latency.
    produced: usize,
    drained: bool,
}

impl TimeStretch {
    pub fn new(rate: f64) -> Self {
        // Periodic Hann, so the overlap sum is flat across the interior.
        let window: Vec<f32> = (0..FRAME)
            .map(|i| 0.5 - 0.5 * (2.0 * PI * i as f32 / FRAME as f32).cos())
            .collect();
        Self {
            window,
            fifo: Vec::new(),
            base: 0,
            accum: vec![0.0f32; FRAME * 2],
            weight: vec![0.0f32; FRAME],
            out: Vec::new(),
            anchor: 0,
            anchor_frac: 0.0,
            placed: None,
            rate: rate.clamp(0.5, 2.0),
            produced: 0,
            drained: false,
        }
    }

    /// Left sample of the frame at absolute input index `frame_index`.
    fn left_at(&self, frame_index: usize) -> f32 {
        self.fifo[(frame_index - self.base) * 2]
    }

    /// Right sample of the frame at absolute input index `frame_index`.
    fn right_at(&self, frame_index: usize) -> f32 {
        self.fifo[(frame_index - self.base) * 2 + 1]
    }

    /// Absolute input index one past the last frame held — the ceiling on any
    /// read. Not `fifo.len()`: once [`TimeStretch::reclaim`] has dropped
    /// consumed input, the length is what is *left*, and every bound here is an
    /// absolute position. Comparing the two is how the stage stops advancing
    /// partway through a track and silently truncates it.
    fn limit(&self) -> usize {
        self.base + self.fifo.len() / 2
    }

    /// Mid (L+R)/2 of the frame at absolute input index `frame_index`, for the
    /// similarity search.
    fn mid_at(&self, frame_index: usize) -> f32 {
        let index = (frame_index - self.base) * 2;
        0.5 * (self.fifo[index] + self.fifo[index + 1])
    }

    /// Changes the stretch ratio mid-stream. Safe at any point: the overlap-add
    /// state and the anchor are untouched, so a rate change is heard as a glide
    /// rather than as a splice.
    pub fn set_rate(&mut self, rate: f64) {
        self.rate = rate.clamp(0.5, 2.0);
    }

    pub fn rate(&self) -> f64 {
        self.rate
    }

    /// Hands over everything produced so far and returns it.
    pub fn take(&mut self) -> Vec<f32> {
        core::mem::take(&mut self.out)
    }

    /// How many source frames the stage has read past the analysis anchor.
    ///
    /// The anchor is the source position of the next output hop, and the pump
    /// will not emit one until a frame plus the search window sits past it, so
    /// this stays near `FRAME + SEARCH` instead of growing with the stream.
    /// Reporting `produced * rate` instead would walk, because the anchor moves
    /// in whole frames and the nominal rate does not.
    pub fn latency_frames(&self) -> f64 {
        self.limit().saturating_sub(self.anchor) as f64
    }

    /// Consumes interleaved stereo input. Returns whatever output is ready,
    /// which may be empty — the stage holds roughly a frame before it has
    /// anything to say, and returning nothing is how that is expressed.
    pub fn process(&mut self, input: &[f32]) {
        self.fifo.extend_from_slice(input);
        self.pump();
    }

    /// Consumes interleaved stereo input and hands back everything that is
    /// ready. May be empty — the stage holds roughly a frame before it has
    /// anything to say, and an empty return is how that is expressed. A caller
    /// on a decode loop should treat that as "not yet", not as "finished".
    pub fn process_and_take(&mut self, input: &[f32]) -> Vec<f32> {
        self.process(input);
        self.take()
    }

    /// Finishes the stream: places the remaining frames and emits whatever is
    /// left, so the output ends sample-aligned with the input. After this the
    /// stage can be dropped without a splice.
    ///
    /// The drain runs at unity whatever the rate was. A tail is the end of the
    /// recording, and the end of the recording plays at its own speed — the
    /// point of retiring the stage here is to hand back to a plain pass-through,
    /// and a pass-through that stretched the last 12 ms would be the seam this
    /// exists to avoid.
    pub fn flush(&mut self) {
        if self.drained {
            return;
        }
        self.drained = true;
        self.rate = 1.0;
        // No search from here: with no more input there is nothing to match
        // against, and the natural continuation is what the ear expects at the
        // end of a file.
        while self.limit() >= self.anchor + FRAME {
            let at = self.anchor;
            self.place(at);
        }
        // The accumulator's remaining window, normalised by the weight that
        // actually landed on each sample. Past the end of the input both are
        // zero, and the floor turns that into silence rather than a divide.
        for frame in 0..FRAME {
            // The window is zero at its first sample, so the divisor can be too.
            // The floor is only here to turn a 0/0 into silence; anywhere the
            // weight is merely small, dividing by it is the correct
            // reconstruction rather than a distortion.
            let norm = self.weight[frame].max(WEIGHT_FLOOR);
            self.out.push(self.accum[frame * 2] / norm);
            self.out.push(self.accum[frame * 2 + 1] / norm);
        }
        // The accumulator reaches to the end of the last frame that was
        // *placed*, which after a hop is one HOP behind the anchor. Anchoring
        // this on the anchor instead skips those samples — 128 of them, an
        // eighth of a frame's worth of the end of the record, silently.
        let end = self.placed.map(|placed| placed + FRAME).unwrap_or(0);
        if end < self.limit() {
            self.out
                .extend_from_slice(&self.fifo[(end - self.base) * 2..]);
        }
        self.produced = self.out.len() / 2;
        self.anchor = self.fifo.len() / 2;
    }

    /// Emits output while the input allows a frame to be placed.
    fn pump(&mut self) {
        loop {
            // The search can reach `SEARCH` either side of the anchor, and a
            // placement needs a whole frame of input after it, so the furthest
            // one it could choose is the one the input has to cover.
            if self.limit() < self.anchor + SEARCH as usize + FRAME {
                break;
            }
            let at = self.best_offset();
            self.place(at);
        }
        self.reclaim();
    }

    /// Drops input the anchor has moved past. Everything still reachable is
    /// within `FRAME` behind the last placement — that is the similarity
    /// reference — so two frames of slack is generous.
    fn reclaim(&mut self) {
        let horizon = self.placed.unwrap_or(self.anchor).saturating_sub(FRAME * 2);
        if horizon > self.base {
            let drop = horizon - self.base;
            self.fifo.drain(..drop * 2);
            self.base = horizon;
        }
    }

    /// The placement that best continues the previous frame.
    ///
    /// Of the offsets within `SEARCH` of the anchor, the one whose head
    /// correlates best with the input continuing from where the last frame
    /// landed. Normalised, so a quiet stretch of input cannot win on level
    /// alone.
    fn best_offset(&self) -> usize {
        let Some(previous) = self.placed else {
            return self.anchor;
        };
        // The last frame ran from `previous` for FRAME samples but only HOP of
        // them have been emitted, so the part of it still to come is what the
        // next frame has to pick up in phase.
        let reference = previous + HOP;
        let limit = self.limit();
        if reference + CORRELATE > limit {
            return self.anchor;
        }
        let reference_mono: Vec<f32> =
            (0..CORRELATE).map(|i| self.mid_at(reference + i)).collect();
        let reference_energy: f32 =
            reference_mono.iter().map(|s| s * s).sum::<f32>().max(1.0e-9);

        let earliest = self.anchor.saturating_sub(SEARCH as usize);
        let mut best = self.anchor;
        let mut best_score = f32::NEG_INFINITY;
        // Walk outwards from the anchor so a tie resolves to the anchor — the
        // identity choice, and the one that makes a rate of 1.0 exact.
        for distance in 0..=SEARCH as usize {
            let mut considered = false;
            for candidate in [
                self.anchor.checked_sub(distance),
                if distance == 0 {
                    None
                } else {
                    Some(self.anchor + distance)
                },
            ] {
                let Some(candidate) = candidate else { continue };
                if candidate < earliest || candidate + FRAME > limit {
                    continue;
                }
                considered = true;
                let mut dot = 0.0f32;
                let mut energy = 0.0f32;
                for i in 0..CORRELATE {
                    let sample = self.mid_at(candidate + i);
                    dot += sample * reference_mono[i];
                    energy += sample * sample;
                }
                let score = dot / (reference_energy * energy).sqrt();
                if score > best_score {
                    best_score = score;
                    best = candidate;
                }
            }
            if considered && best_score > 0.999 {
                // A near-perfect match at the anchor; nothing further out is
                // going to beat it.
                break;
            }
        }
        best
    }

    /// Windows the frame at `at` into the accumulator and emits one hop.
    fn place(&mut self, at: usize) {
        for frame in 0..FRAME {
            let weight = self.window[frame];
            let left = self.left_at(at + frame);
            let right = self.right_at(at + frame);
            self.accum[frame * 2] += left * weight;
            self.accum[frame * 2 + 1] += right * weight;
            self.weight[frame] += weight;
        }
        for frame in 0..HOP {
            let norm = self.weight[frame].max(WEIGHT_FLOOR);
            self.out.push(self.accum[frame * 2] / norm);
            self.out.push(self.accum[frame * 2 + 1] / norm);
        }
        self.produced += HOP;
        // Slide the accumulator along by one hop and zero what is left.
        self.accum.copy_within(HOP * 2..FRAME * 2, 0);
        self.weight.copy_within(HOP..FRAME, 0);
        for sample in (FRAME - HOP) * 2..FRAME * 2 {
            self.accum[sample] = 0.0;
        }
        for frame in FRAME - HOP..FRAME {
            self.weight[frame] = 0.0;
        }
        self.placed = Some(at);
        // Playback speed: consume `HOP * rate` input frames for this output hop,
        // from the anchor's own value and *not* from where this frame landed.
        // At unity this is HOP and the stage reconstructs the input. Above 1 the
        // record plays faster. The fraction is kept so a rate like 120/116 does
        // not walk by half a sample per hop across a long blend.
        let step = HOP as f64 * self.rate + self.anchor_frac;
        let whole = step.floor() as usize;
        self.anchor_frac = step - whole as f64;
        self.anchor += whole.max(1);
    }
}

/// One-shot WSOLA over a whole buffer. Test helper: the streaming path is the
/// real one, and comparing against this is what proves the streaming path
/// behaves the same.
pub fn stretch_whole(input: &[f32], rate: f64) -> Vec<f32> {
    let mut stretcher = TimeStretch::new(rate);
    stretcher.process(input);
    stretcher.flush();
    stretcher.take()
}

#[cfg(test)]
mod tests {
    use super::*;
    // The module aliases `PI` as f32; the measurement helpers here are f64.
    use core::f64::consts::PI as TAU;

    const RATE: u32 = 48_000;

    /// A tone plus a second an octave up, so a pitch error cannot hide behind
    /// a single partial.
    fn tone(frames: usize, hz: f64) -> Vec<f32> {
        (0..frames * 2)
            .map(|i| {
                let t = (i / 2) as f64 / RATE as f64;
                let value = (2.0 * TAU * hz * t).sin() + 0.5 * (2.0 * TAU * 2.0 * hz * t).sin();
                ((value / 1.5) as f32) * 0.5
            })
            .collect()
    }

    /// Dominant frequency by Goertzel at three neighbouring bins, with a
    /// parabolic fit through the magnitudes — cheap, and tight enough to tell a
    /// preserved 220 Hz from a resampled 226.6 Hz.
    fn frequency_at(samples: &[f32], hz: f64, start: usize, frames: usize) -> f64 {
        let magnitude = |probe: f64| -> f64 {
            let w = 2.0 * TAU * probe / RATE as f64;
            let coeff = 2.0 * w.cos();
            let (mut s1, mut s2) = (0.0f64, 0.0f64);
            for i in start..start + frames {
                let s0 = samples[i * 2] as f64 + coeff * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
            (s1 * s1 + s2 * s2 - coeff * s1 * s2).max(0.0)
        };
        let step = 1.0f64;
        let before = magnitude(hz - step);
        let centre = magnitude(hz);
        let after = magnitude(hz + step);
        let denominator = before - 2.0 * centre + after;
        if denominator.abs() < 1.0e-12 {
            return hz;
        }
        hz + 0.5 * step * (before - after) / denominator
    }

    fn cents_off(measured: f64, expected: f64) -> f64 {
        1200.0 * (measured / expected).log2()
    }

    #[test]
    fn unity_rate_reconstructs_the_input() {
        let input = tone(RATE as usize * 2, 220.0);
        let output = stretch_whole(&input, 1.0);
        // The stage holds a frame before it emits, so the output is the input
        // delayed. Find that delay rather than assuming it, then require the two
        // to match once it is accounted for — which also pins the latency.
        let end = (input.len() / 2).min(output.len() / 2) - FRAME * 2;
        let mut best_delay = 0usize;
        let mut best_error = f32::INFINITY;
        for delay in 0..(FRAME * 2) {
            let mut worst = 0.0f32;
            for i in FRAME * 4..end {
                let at = i * 2;
                worst = worst
                    .max((output[at + delay * 2] - input[at]).abs())
                    .max((output[at + delay * 2 + 1] - input[at + 1]).abs());
            }
            if worst < best_error {
                best_error = worst;
                best_delay = delay;
            }
        }
        assert!(
            best_error < 1.0e-3,
            "unity rate should reconstruct the input, worst sample error {best_error} \
             at a delay of {best_delay} frames"
        );
        assert!(
            best_delay <= FRAME + SEARCH as usize,
            "latency of {best_delay} frames exceeded the {FRAME}+{SEARCH} bound"
        );
    }

    #[test]
    fn a_faster_speed_shortens_the_stream() {
        // `rate` is a playback speed. 1.03 plays the record slightly fast, so
        // the same audio takes less room; 0.97 plays it slow and takes more.
        let input = tone(RATE as usize * 3, 220.0);
        let base = input.len() as f64;
        let faster = stretch_whole(&input, 1.03).len() as f64;
        let slower = stretch_whole(&input, 0.97).len() as f64;
        assert!(
            faster < base * 0.98,
            "1.03 should shorten the stream, got {faster} vs {base}"
        );
        assert!(
            slower > base * 1.02,
            "0.97 should lengthen the stream, got {slower} vs {base}"
        );
    }

    #[test]
    fn stretching_preserves_pitch() {
        // The whole point. A resampler would move 220 Hz to 226.6 Hz here —
        // 51 cents, plainly audible as a bend.
        for rate in [0.97f64, 1.03] {
            let input = tone(RATE as usize * 4, 220.0);
            let output = stretch_whole(&input, rate);
            let start = FRAME * 8;
            let frames = RATE as usize / 2;
            assert!(output.len() > (start + frames) * 2 + 2);
            let cents = cents_off(frequency_at(&output, 220.0, start, frames), 220.0);
            assert!(
                cents.abs() < 12.0,
                "rate {rate} moved 220 Hz by {cents:.1} cents — that is a resampler, not WSOLA"
            );
        }
    }

    #[test]
    fn streaming_in_chunks_matches_the_whole_buffer() {
        let input = tone(RATE as usize * 3, 220.0);
        let whole = stretch_whole(&input, 1.031);
        // Feed in deliberately awkward pieces, including ones smaller than a
        // single frame, so the search is exercised mid-frame as well as on
        // frame boundaries.
        let mut streamed = TimeStretch::new(1.031);
        let mut at = 0usize;
        let mut sizes = vec![1024usize, 512, 96, 4096, 2048];
        while at < input.len() {
            let take = sizes.remove(0).min((input.len() - at) / 2) * 2;
            sizes.push(1024);
            streamed.process(&input[at..at + take]);
            at += take;
        }
        streamed.flush();
        let chunked = streamed.take();
        assert_eq!(
            chunked.len(),
            whole.len(),
            "chunking changed the output length"
        );
        let mut worst = 0.0f32;
        for i in 0..whole.len() {
            worst = worst.max((whole[i] - chunked[i]).abs());
        }
        assert!(
            worst < 1.0e-3,
            "chunked streaming diverged from the whole buffer by {worst}"
        );
    }

    #[test]
    fn latency_is_bounded_and_does_not_grow() {
        let mut stretcher = TimeStretch::new(0.97);
        let mut first = 0.0f64;
        for _ in 0..200 {
            stretcher.process(&tone(2048, 220.0));
            let latency = stretcher.latency_frames();
            if first == 0.0 {
                first = latency;
            }
            assert!(
                latency <= (FRAME + SEARCH as usize) as f64,
                "latency {latency} frames exceeded the {FRAME}+{SEARCH} bound"
            );
            // The fifo stops filling within one hop of the lookahead the pump
            // asks for, so the reading jitters by a hop and must not walk.
            assert!(
                (latency - first).abs() < HOP as f64,
                "latency drifted from {first} to {latency} — it must not accumulate"
            );
        }
    }

    #[test]
    fn the_search_cannot_drift_the_effective_rate() {
        // A search that advances the anchor from where it placed the last frame
        // lets its own choice set the rate: each frame can be `SEARCH` samples
        // off its aim and the error compounds. A long steady tone is the worst
        // case for it, so the measured length over four seconds is the assertion.
        let input = tone(RATE as usize * 4, 220.0);
        // Playback speed: the record occupies `1 / rate` of its original length.
        for rate in [0.97f64, 1.03] {
            let output = stretch_whole(&input, rate).len() as f64;
            let ratio = output / input.len() as f64;
            let expected = 1.0 / rate;
            assert!(
                (ratio - expected).abs() < 0.005,
                "asked for speed {rate}, expected a length ratio of {expected:.4}, got {ratio:.4}"
            );
        }
    }

    /// 116 BPM clicks played at 120/116 must land on a 120 BPM grid.
    ///
    /// This is the handoff the mixer asks for: a slower incoming track sped up
    /// to the outgoing tempo, with the spacing — not just the length — matching.
    #[test]
    fn clicks_sped_up_from_116_land_on_120() {
        let speed = 120.0 / 116.0;
        let input = clicks_at(116.0, 16);
        let output = stretch_whole(&input, speed);
        let spacing = onset_spacing(&output);
        assert!(
            spacing.len() >= 12,
            "expected a click per beat, found {} gaps",
            spacing.len()
        );
        let expected = RATE as f64 * 60.0 / 120.0;
        for gap in spacing {
            let error = (gap as f64 - expected).abs() / expected;
            assert!(
                error < 0.01,
                "onset spacing {gap} samples is {error:.3} off a 120 BPM grid ({expected:.0})"
            );
        }
    }

    /// Clicks: a short decaying burst on each beat, long enough for the
    /// similarity search to lock and short enough that the onset is the burst.
    fn clicks_at(bpm: f64, beats: usize) -> Vec<f32> {
        let interval = (RATE as f64 * 60.0 / bpm).round() as usize;
        let burst = RATE as usize * 8 / 1000;
        let frames = interval * beats + RATE as usize;
        let mut samples = vec![0.0f32; frames * 2];
        for beat in 0..beats {
            let start = beat * interval;
            for i in 0..burst {
                let t = i as f64 / RATE as f64;
                let env = (-t * 500.0).exp();
                let value = (env * (2.0 * TAU * 1000.0 * t).sin()) as f32;
                let at = (start + i) * 2;
                samples[at] = value;
                samples[at + 1] = value;
            }
        }
        samples
    }

    /// Peak-pick onsets, with a refractory so one burst is one onset.
    fn onset_spacing(samples: &[f32]) -> Vec<usize> {
        let frames = samples.len() / 2;
        let mut peaks = Vec::new();
        let mut i = 1usize;
        while i + 1 < frames {
            let level = samples[i * 2].abs();
            if level > 0.25
                && level >= samples[(i - 1) * 2].abs()
                && level >= samples[(i + 1) * 2].abs()
            {
                peaks.push(i);
                i += RATE as usize / 10;
            } else {
                i += 1;
            }
        }
        peaks.windows(2).map(|pair| pair[1] - pair[0]).collect()
    }

    #[test]
    fn a_rate_change_mid_stream_is_a_glide_not_a_splice() {
        let input = tone(RATE as usize * 4, 220.0);
        let mut stretcher = TimeStretch::new(1.0);
        let mut output = Vec::new();
        let mut at = 0usize;
        let half = input.len() / 4;
        while at < input.len() {
            if at >= half {
                stretcher.set_rate(0.97);
            }
            let take = 2048.min(input.len() - at);
            stretcher.process(&input[at..at + take]);
            output.extend(stretcher.take());
            at += take;
        }
        stretcher.flush();
        output.extend(stretcher.take());
        // The tone must still be a tone: a splice would put a discontinuity
        // into it, and the measurement below would not find a peak.
        let measured = frequency_at(&output, 220.0, FRAME * 4, RATE as usize / 2);
        let cents = cents_off(measured, 220.0);
        assert!(
            cents.abs() < 12.0,
            "a rate change bent the pitch by {cents:.1} cents"
        );
    }
}



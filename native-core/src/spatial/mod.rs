//! SpatialRenderer (spec §3.3): verbatim f32 port of upstream
//! `SpatialAudioProcessor` — mid/side widening + delayed one-pole-lowpassed
//! crossfeed, applied per stream pre-mix, sample-identical passthrough when
//! disabled.
//!
//! Head tracking is a *post* stage: Woodworth ITD + ILD on the already-widened
//! signal, so the 15 ms Haas delay stays identical to upstream. Yaw 0 is a
//! hard skip — sample-identical to the Kotlin processor. An earlier port
//! stretched the Haas taps by yaw and wrecked the image.

/// Mid/side widening + crossfeed stage for one stereo stream.
pub struct SpatialRenderer {
    sample_rate: u32,
    enabled: bool,

    /// How much wider the stereo image gets. 1.0 = untouched.
    width_gain: f32,
    /// Makeup attenuation after widening, so the wider side energy doesn't clip.
    output_gain: f32,
    /// How much of the delayed, low-passed opposite channel gets mixed back in.
    crossfeed_gain: f32,
    /// One-pole lowpass factor applied to the cross-fed signal — dulls it, like a far ear would.
    lowpass_coeff: f32,

    /// Per-channel delay lines, matching upstream's `delayLeft`/`delayRight`.
    delay_left: Vec<f32>,
    delay_right: Vec<f32>,
    delay_index: usize,
    lowpass_left: f32,
    lowpass_right: f32,

    /// Head yaw, −1..1 (−90°..+90°). Positive = head turned left
    /// (`CMAttitude.yaw` > 0): the image is shifted right so it stays
    /// device-locked.
    head_yaw: f32,
    yaw_smooth: f32,
    yaw_alpha: f32,

    /// Short fractional-delay lines for the post-widen ITD (≤ 0.66 ms).
    itd_left: Vec<f32>,
    itd_right: Vec<f32>,
    itd_index: usize,
    max_itd: f32,
}

const DELAY_MS: f32 = 15.0;
/// Human-head ITD at 90° (Woodworth). Must stay off the 15 ms Haas line.
const MAX_ITD_SECS: f32 = 0.00066;
const MAX_ILD_DB: f32 = 4.0;
const YAW_SMOOTH_SECS: f32 = 0.04;

impl SpatialRenderer {
    pub fn new(sample_rate: u32) -> Self {
        let delay_samples = delay_len(sample_rate);
        let itd_samples = itd_len(sample_rate);
        let sr = sample_rate.max(1) as f32;
        Self {
            sample_rate,
            enabled: false,
            width_gain: 2.5,
            output_gain: 0.82,
            crossfeed_gain: 0.2,
            lowpass_coeff: 0.3,
            delay_left: vec![0.0; delay_samples],
            delay_right: vec![0.0; delay_samples],
            delay_index: 0,
            lowpass_left: 0.0,
            lowpass_right: 0.0,
            head_yaw: 0.0,
            yaw_smooth: 0.0,
            yaw_alpha: 1.0 - (-1.0 / (YAW_SMOOTH_SECS * sr)).exp(),
            itd_left: vec![0.0; itd_samples],
            itd_right: vec![0.0; itd_samples],
            itd_index: 0,
            max_itd: (sr * MAX_ITD_SECS).min((itd_samples - 1) as f32),
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn set_head_yaw(&mut self, yaw: f32) {
        self.head_yaw = yaw.clamp(-1.0, 1.0);
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Flushes filter state — upstream's `onFlush` (seek / fresh source).
    pub fn flush(&mut self) {
        self.delay_left.fill(0.0);
        self.delay_right.fill(0.0);
        self.delay_index = 0;
        self.lowpass_left = 0.0;
        self.lowpass_right = 0.0;
        self.itd_left.fill(0.0);
        self.itd_right.fill(0.0);
        self.itd_index = 0;
    }

    /// Processes interleaved stereo f32 in place (`samples.len()` even).
    ///
    /// Disabled: returns without touching the buffer — sample-identical
    /// passthrough, the semantic upstream guarantees.
    pub fn process(&mut self, samples: &mut [f32]) {
        if !self.enabled || samples.len() < 2 {
            return;
        }

        let delay_size = self.delay_left.len();
        if delay_size == 0 {
            return;
        }

        for chunk in samples.chunks_exact_mut(2) {
            // Float decoders can overshoot ±1; int16 (upstream's domain) cannot.
            // A 2.5× side gain on a hot sample hard-clips into hash. Bound the
            // input the way a short sample is inherently bounded.
            let left = chunk[0].clamp(-1.0, 1.0);
            let right = chunk[1].clamp(-1.0, 1.0);

            let mid = (left + right) * 0.5;
            let side = (left - right) * 0.5 * self.width_gain;
            let mut widened_left = mid + side;
            let mut widened_right = mid - side;

            // Read the oldest sample (the slot about to be overwritten) — full
            // DELAY_MS. Same as `delayRight[delayIndex]` before the write.
            let delayed_right = self.delay_right[self.delay_index];
            let delayed_left = self.delay_left[self.delay_index];
            self.lowpass_left += self.lowpass_coeff * (delayed_right - self.lowpass_left);
            self.lowpass_right += self.lowpass_coeff * (delayed_left - self.lowpass_right);
            widened_left += self.lowpass_left * self.crossfeed_gain;
            widened_right += self.lowpass_right * self.crossfeed_gain;

            self.delay_left[self.delay_index] = left;
            self.delay_right[self.delay_index] = right;
            self.delay_index = (self.delay_index + 1) % delay_size;

            chunk[0] = clamp_unit(widened_left * self.output_gain);
            chunk[1] = clamp_unit(widened_right * self.output_gain);
            let (l, r) = self.head_lock(chunk[0], chunk[1]);
            chunk[0] = l;
            chunk[1] = r;
        }
    }

    /// Device-locked image: delay/attenuate the far ear. At yaw 0 this is a
    /// no-op so the widening stays bit-identical to upstream.
    fn head_lock(&mut self, left: f32, right: f32) -> (f32, f32) {
        self.yaw_smooth += self.yaw_alpha * (self.head_yaw - self.yaw_smooth);

        let n = self.itd_left.len();
        self.itd_left[self.itd_index] = left;
        self.itd_right[self.itd_index] = right;

        if self.head_yaw.abs() <= 1e-6 && self.yaw_smooth.abs() <= 1e-6 {
            self.itd_index = (self.itd_index + 1) % n;
            return (left, right);
        }

        let az = self.yaw_smooth;
        // Head left (az > 0) → image sits to the right of the nose: left
        // ear is the far ear.
        let out_l = read_frac(&self.itd_left, self.itd_index, (az * self.max_itd).max(0.0));
        let out_r = read_frac(&self.itd_right, self.itd_index, ((-az) * self.max_itd).max(0.0));
        self.itd_index = (self.itd_index + 1) % n;

        (
            clamp_unit(out_l * db_gain(-MAX_ILD_DB * az.max(0.0))),
            clamp_unit(out_r * db_gain(-MAX_ILD_DB * (-az).max(0.0))),
        )
    }
}

fn delay_len(sample_rate: u32) -> usize {
    ((sample_rate as f32 * DELAY_MS / 1000.0).round() as usize).max(1)
}

fn itd_len(sample_rate: u32) -> usize {
    ((sample_rate as f32 * MAX_ITD_SECS).ceil() as usize).max(2) + 1
}

fn db_gain(db: f32) -> f32 {
    10.0f32.powf(db / 20.0)
}

fn read_frac(buf: &[f32], write: usize, delay: f32) -> f32 {
    let max = (buf.len() - 1) as f32;
    let d = delay.clamp(0.0, max);
    let i0 = d.floor() as usize;
    let frac = d - i0 as f32;
    let n = buf.len();
    let a = buf[(write + n - i0) % n];
    if frac <= 0.0 {
        return a;
    }
    let b = buf[(write + n - (i0 + 1)) % n];
    a + (b - a) * frac
}

/// f32 analogue of upstream's clamp-to-int16: keeps the widened signal inside
/// the range the output stage can carry, so a widened peak never wraps
/// downstream.
fn clamp_unit(value: f32) -> f32 {
    value.clamp(-1.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_is_sample_identical_passthrough() {
        let mut renderer = SpatialRenderer::new(48_000);
        renderer.set_enabled(false);
        let input: Vec<f32> = (0..4800).map(|i| ((i as f32) * 0.01).sin() * 0.5).collect();
        let mut buf = input.clone();
        renderer.process(&mut buf);
        assert_eq!(buf, input);
    }

    #[test]
    fn enabled_changes_signal_and_stays_bounded() {
        let mut renderer = SpatialRenderer::new(48_000);
        renderer.set_enabled(true);
        let input: Vec<f32> = (0..48_000)
            .map(|i| ((i as f32) * 0.02).sin() * 0.9)
            .collect();
        let mut buf = input.clone();
        renderer.process(&mut buf);
        assert_ne!(buf, input);
        assert!(buf.iter().all(|v| v.is_finite() && v.abs() <= 1.0));
    }

    #[test]
    fn delay_line_is_full_window_not_one_sample() {
        // A left impulse must show up in the right-channel crossfeed only
        // after DELAY_MS, not on the next sample (the yaw-tap bug).
        let rate = 48_000u32;
        let delay = delay_len(rate);
        let mut renderer = SpatialRenderer::new(rate);
        renderer.set_enabled(true);

        let frames = delay + 8;
        let mut buf = vec![0.0f32; frames * 2];
        buf[0] = 0.8; // left impulse at frame 0

        renderer.process(&mut buf);

        // Frame 1 (right after the impulse): right should still be the dry
        // mid/side of (0.8, 0) with no crossfeed yet — delay is zeros.
        // Frame `delay` is when the impulse is read back as delayed_left.
        let right_at_1 = buf[3].abs();
        let right_at_delay = buf[delay * 2 + 1].abs();
        assert!(
            right_at_delay > right_at_1 * 2.0,
            "crossfeed should land at the 15ms tap (frame {delay}), not immediately; \
             |R[1]|={right_at_1} |R[{delay}]|={right_at_delay}"
        );
    }

    #[test]
    fn matches_upstream_int16_math_on_normalized_pcm() {
        // Bit-exact against a scalar transcription of SpatialAudioProcessor
        // queueInput, in the normalized domain (sample / 32768).
        let rate = 44_100u32;
        let mut renderer = SpatialRenderer::new(rate);
        renderer.set_enabled(true);

        let frames = 2_048usize;
        let input: Vec<f32> = (0..frames * 2)
            .map(|i| {
                let t = (i / 2) as f32 / rate as f32;
                let s = (2.0 * std::f32::consts::PI * 440.0 * t).sin() * 0.6;
                if i % 2 == 0 {
                    s
                } else {
                    s * 0.4
                }
            })
            .collect();
        let mut buf = input.clone();
        renderer.process(&mut buf);

        let expected = reference_upstream(&input, rate);
        assert_eq!(buf.len(), expected.len());
        for (i, (got, want)) in buf.iter().zip(expected.iter()).enumerate() {
            let err = (got - want).abs();
            assert!(
                err < 1e-6,
                "sample {i}: got {got} want {want} err {err}"
            );
        }
    }

    #[test]
    fn zero_yaw_is_bit_identical_to_no_head_lock() {
        let rate = 48_000u32;
        let input: Vec<f32> = (0..8_000)
            .map(|i| {
                let t = (i / 2) as f32 / rate as f32;
                (2.0 * std::f32::consts::PI * 330.0 * t).sin() * if i % 2 == 0 { 0.5 } else { 0.3 }
            })
            .collect();

        let mut plain = SpatialRenderer::new(rate);
        plain.set_enabled(true);
        let mut a = input.clone();
        plain.process(&mut a);

        let mut locked = SpatialRenderer::new(rate);
        locked.set_enabled(true);
        locked.set_head_yaw(0.0);
        let mut b = input.clone();
        locked.process(&mut b);
        assert_eq!(a, b);
    }

    #[test]
    fn nonzero_yaw_shifts_image_and_stays_bounded() {
        let rate = 48_000u32;
        let input: Vec<f32> = (0..8_000)
            .map(|i| ((i as f32) * 0.01).sin() * 0.7)
            .collect();

        let mut a = SpatialRenderer::new(rate);
        a.set_enabled(true);
        let mut leftish = input.clone();
        a.process(&mut leftish);

        let mut b = SpatialRenderer::new(rate);
        b.set_enabled(true);
        b.set_head_yaw(0.8);
        let mut rightish = input.clone();
        b.process(&mut rightish);

        assert_ne!(leftish, rightish);
        assert!(rightish.iter().all(|v| v.is_finite() && v.abs() <= 1.0));
    }
}

/// Scalar copy of `SpatialAudioProcessor.queueInput` in f32 −1..1.
#[cfg(test)]
fn reference_upstream(input: &[f32], sample_rate: u32) -> Vec<f32> {
    let delay_size = delay_len(sample_rate);
    let mut delay_left = vec![0.0f32; delay_size];
    let mut delay_right = vec![0.0f32; delay_size];
    let mut delay_index = 0usize;
    let mut lowpass_left = 0.0f32;
    let mut lowpass_right = 0.0f32;
    let width_gain = 2.5f32;
    let output_gain = 0.82f32;
    let crossfeed_gain = 0.2f32;
    let lowpass_coeff = 0.3f32;
    let mut out = Vec::with_capacity(input.len());
    for pair in input.chunks_exact(2) {
        let left = pair[0].clamp(-1.0, 1.0);
        let right = pair[1].clamp(-1.0, 1.0);
        let mid = (left + right) * 0.5;
        let side = (left - right) * 0.5 * width_gain;
        let mut widened_left = mid + side;
        let mut widened_right = mid - side;
        let delayed_right = delay_right[delay_index];
        let delayed_left = delay_left[delay_index];
        lowpass_left += lowpass_coeff * (delayed_right - lowpass_left);
        lowpass_right += lowpass_coeff * (delayed_left - lowpass_right);
        widened_left += lowpass_left * crossfeed_gain;
        widened_right += lowpass_right * crossfeed_gain;
        delay_left[delay_index] = left;
        delay_right[delay_index] = right;
        delay_index = (delay_index + 1) % delay_size;
        out.push((widened_left * output_gain).clamp(-1.0, 1.0));
        out.push((widened_right * output_gain).clamp(-1.0, 1.0));
    }
    out
}

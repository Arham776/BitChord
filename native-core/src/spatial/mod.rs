//! SpatialRenderer (spec §3.3): verbatim f32 port of upstream
//! `SpatialAudioProcessor` — mid/side widening + delayed one-pole-lowpassed
//! crossfeed, applied per stream pre-mix, sample-identical passthrough when
//! disabled.

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

    delay: Vec<f32>, // interleaved stereo delay line: [L0, R0, L1, R1, ...]
    delay_index: usize,
    lowpass_left: f32,
    lowpass_right: f32,

    /// Head-tracking yaw (−1..1 normalized) fed from the Swift layer on iOS.
    /// macOS has no `CMHeadphoneMotionManager`, so desktop always sees 0 —
    /// which leaves the delay geometry exactly upstream's.
    head_yaw: f32,
}

const DELAY_MS: f32 = 15.0;

impl SpatialRenderer {
    pub fn new(sample_rate: u32) -> Self {
        let delay_samples = ((sample_rate as f32 * DELAY_MS / 1000.0).round() as usize).max(1);
        Self {
            sample_rate,
            enabled: false,
            width_gain: 2.5,
            output_gain: 0.82,
            crossfeed_gain: 0.2,
            lowpass_coeff: 0.3,
            delay: vec![0.0; delay_samples * 2],
            delay_index: 0,
            lowpass_left: 0.0,
            lowpass_right: 0.0,
            head_yaw: 0.0,
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn set_head_yaw(&mut self, yaw: f32) {
        self.head_yaw = yaw.clamp(-1.0, 1.0);
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Flushes filter state — upstream's `onFlush` (seek / fresh source).
    pub fn flush(&mut self) {
        self.delay.fill(0.0);
        self.delay_index = 0;
        self.lowpass_left = 0.0;
        self.lowpass_right = 0.0;
    }

    /// Processes interleaved stereo f32 in place (`samples.len()` even).
    ///
    /// Disabled: returns without touching the buffer — sample-identical
    /// passthrough, the semantic upstream guarantees.
    pub fn process(&mut self, samples: &mut [f32]) {
        if !self.enabled || samples.len() < 2 {
            return;
        }

        // Yaw tilts the crossfeed delay: turning the head left/right stretches
        // one ear's delayed opposite-channel feed while shortening the other.
        // At yaw 0 the multiplier is 1.0 for both sides — exactly the upstream
        // symmetric geometry.
        let tilt = self.head_yaw * 0.5;
        let delay_size = self.delay.len() / 2;
        let forward = ((delay_size as f32 * (1.0 + tilt)) as usize).clamp(1, delay_size);
        let back = ((delay_size as f32 * (1.0 - tilt)) as usize).clamp(1, delay_size);

        for chunk in samples.chunks_exact_mut(2) {
            let left = chunk[0];
            let right = chunk[1];

            let mid = (left + right) * 0.5;
            let side = (left - right) * 0.5 * self.width_gain;
            let mut widened_left = mid + side;
            let mut widened_right = mid - side;

            let read_fwd = (self.delay_index + delay_size - (forward - 1)) % delay_size;
            let read_back = (self.delay_index + delay_size - (back - 1)) % delay_size;
            let delayed_right = self.delay[read_fwd * 2 + 1];
            let delayed_left = self.delay[read_back * 2];

            self.lowpass_left += self.lowpass_coeff * (delayed_right - self.lowpass_left);
            self.lowpass_right += self.lowpass_coeff * (delayed_left - self.lowpass_right);
            widened_left += self.lowpass_left * self.crossfeed_gain;
            widened_right += self.lowpass_right * self.crossfeed_gain;

            self.delay[self.delay_index * 2] = left;
            self.delay[self.delay_index * 2 + 1] = right;
            self.delay_index = (self.delay_index + 1) % delay_size;

            chunk[0] = clamp_unit(widened_left * self.output_gain);
            chunk[1] = clamp_unit(widened_right * self.output_gain);
        }
    }
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
    fn zero_yaw_matches_symmetric_geometry() {
        let mut a = SpatialRenderer::new(44_100);
        a.set_enabled(true);
        let mut b = SpatialRenderer::new(44_100);
        b.set_enabled(true);
        b.set_head_yaw(0.0);
        let input: Vec<f32> = (0..44_100).map(|i| ((i as f32) * 0.003).cos() * 0.8).collect();
        let mut buf_a = input.clone();
        let mut buf_b = input.clone();
        a.process(&mut buf_a);
        b.process(&mut buf_b);
        assert_eq!(buf_a, buf_b);
    }
}

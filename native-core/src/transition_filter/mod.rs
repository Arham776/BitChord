//! TransitionFilter (spec §3.5): verbatim port of upstream
//! `TransitionFilterProcessor` — trapezoidal-integrator state-variable
//! Butterworth LP/HP pair (24 dB/oct) with geometrically gliding cutoffs,
//! re-aimed per fade tick for bass hand-off during transitions.
//!
//! All constants are copied verbatim from upstream. The 16-bit PCM gate in the
//! Kotlin is a Media3-sink artifact; this f32 port keeps the clamp behaviour at
//! the unit range instead of int16.

const OPEN_HZ: f32 = 20_000.0;
const OFF_HZ: f32 = 20.0;
const MAX_HIGH_PASS_HZ: f32 = 2_000.0;
const MIN_HZ: f32 = 10.0;
const STAGES: usize = 2;
const BUTTERWORTH_Q: [f32; 2] = [0.54120, 1.30656];
const GLIDE_FRAMES: usize = 64;
const GLIDE_RATE: f32 = 0.05;
const SETTLED_HZ: f32 = 1.0;
const MAX_CUTOFF_FRACTION: f32 = 0.45;

/// One filter instance per stream, driven by the crossfade execution loop —
/// upstream's `TransitionFilters.incoming/outgoing` shape.
pub struct TransitionFilter {
    channels: usize,
    sample_rate: u32,

    target_low_pass_hz: f32,
    target_high_pass_hz: f32,

    current_low_pass_hz: f32,
    current_high_pass_hz: f32,

    /// Two integrator states per second-order section, per channel:
    /// `[ic1, ic2]` pairs flattened as `channel * STAGES * 2 + stage * 2`.
    low_state: Vec<f32>,
    high_state: Vec<f32>,

    low_a1: [f32; STAGES],
    low_a2: [f32; STAGES],
    low_a3: [f32; STAGES],
    high_a1: [f32; STAGES],
    high_a2: [f32; STAGES],
    high_a3: [f32; STAGES],
    high_k: [f32; STAGES],
}

impl TransitionFilter {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let mut filter = Self {
            channels: channels.max(1),
            sample_rate: sample_rate.max(1),
            target_low_pass_hz: OPEN_HZ,
            target_high_pass_hz: OFF_HZ,
            current_low_pass_hz: OPEN_HZ,
            current_high_pass_hz: OFF_HZ,
            low_state: Vec::new(),
            high_state: Vec::new(),
            low_a1: [0.0; STAGES],
            low_a2: [0.0; STAGES],
            low_a3: [0.0; STAGES],
            high_a1: [0.0; STAGES],
            high_a2: [0.0; STAGES],
            high_a3: [0.0; STAGES],
            high_k: [0.0; STAGES],
        };
        filter.configure();
        filter
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn open_hz() -> f32 {
        OPEN_HZ
    }

    pub fn off_hz() -> f32 {
        OFF_HZ
    }

    /// Aims the filter. `low_pass_hz` at or above [`OPEN_HZ`] and
    /// `high_pass_hz` at or below [`OFF_HZ`] mean "not filtering".
    pub fn set_cutoffs(&mut self, low_pass_hz: f32, high_pass_hz: f32) {
        self.target_low_pass_hz = low_pass_hz.clamp(MIN_HZ, OPEN_HZ);
        self.target_high_pass_hz = high_pass_hz.clamp(OFF_HZ, MAX_HIGH_PASS_HZ);
    }

    /// Parks both filters. Glided, not snapped.
    pub fn open(&mut self) {
        self.set_cutoffs(OPEN_HZ, OFF_HZ);
    }

    fn configure(&mut self) {
        self.low_state = vec![0.0; self.channels * STAGES * 2];
        self.high_state = vec![0.0; self.channels * STAGES * 2];
        self.current_low_pass_hz = self.target_low_pass_hz;
        self.current_high_pass_hz = self.target_high_pass_hz;
    }

    /// Flush — a seek or a fresh source. States zeroed and cutoffs snapped
    /// (not glided): there is no continuous signal for a glide to be
    /// continuous with.
    pub fn flush(&mut self) {
        self.low_state.fill(0.0);
        self.high_state.fill(0.0);
        self.current_low_pass_hz = self.target_low_pass_hz;
        self.current_high_pass_hz = self.target_high_pass_hz;
    }

    /// Processes interleaved f32 (`samples.len()` a multiple of `channels`).
    ///
    /// Parked at both ends *and* already settled there: nothing to do but hand
    /// the buffer straight through. The "already settled" half matters — a
    /// transition that has just finished is still gliding back open, and
    /// cutting the filter out from under that glide is the click it exists to
    /// avoid.
    pub fn process(&mut self, samples: &mut [f32]) {
        let ch = self.channels;
        if ch == 0 || samples.is_empty() || samples.len() % ch != 0 {
            return;
        }
        let frame_count = samples.len() / ch;

        let target_low = self.target_low_pass_hz;
        let target_high = self.target_high_pass_hz;
        let parked = target_low >= OPEN_HZ
            && target_high <= OFF_HZ
            && self.current_low_pass_hz >= OPEN_HZ - SETTLED_HZ
            && self.current_high_pass_hz <= OFF_HZ + SETTLED_HZ;
        if parked {
            return;
        }

        let mut remaining = frame_count;
        let mut cursor = 0;
        while remaining > 0 {
            let block = remaining.min(GLIDE_FRAMES);
            self.current_low_pass_hz = Self::glide(self.current_low_pass_hz, target_low);
            self.current_high_pass_hz = Self::glide(self.current_high_pass_hz, target_high);
            let low_on = self.current_low_pass_hz < OPEN_HZ - SETTLED_HZ;
            let high_on = self.current_high_pass_hz > OFF_HZ + SETTLED_HZ;
            if low_on {
                self.update_low_coefficients();
            }
            if high_on {
                self.update_high_coefficients();
            }

            for frame in 0..block {
                for channel in 0..ch {
                    let idx = cursor + frame * ch + channel;
                    let mut value = samples[idx];
                    if low_on {
                        value = self.low_pass(channel, value);
                    }
                    if high_on {
                        value = self.high_pass(channel, value);
                    }
                    // Headroom preserved, matching upstream's float `process`
                    // path — no clamp here; the output boundary clamps.
                    samples[idx] = value;
                }
            }
            cursor += block * ch;
            remaining -= block;
        }
    }

    fn glide(current: f32, target: f32) -> f32 {
        let from = current.max(MIN_HZ).ln();
        let to = target.max(MIN_HZ).ln();
        (from + (to - from) * GLIDE_RATE).exp()
    }

    /// Highest cutoff the bilinear transform can still represent without warping to infinity.
    fn usable_cutoff(&self, hz: f32) -> f32 {
        hz.clamp(MIN_HZ, self.sample_rate as f32 * MAX_CUTOFF_FRACTION)
    }

    fn update_low_coefficients(&mut self) {
        let g = (core::f64::consts::PI * self.usable_cutoff(self.current_low_pass_hz) as f64
            / self.sample_rate as f64)
            .tan() as f32;
        for stage in 0..STAGES {
            let k = 1.0 / BUTTERWORTH_Q[stage];
            let a1 = 1.0 / (1.0 + g * (g + k));
            self.low_a1[stage] = a1;
            self.low_a2[stage] = g * a1;
            self.low_a3[stage] = g * (g * a1);
        }
    }

    fn update_high_coefficients(&mut self) {
        let g = (core::f64::consts::PI * self.usable_cutoff(self.current_high_pass_hz) as f64
            / self.sample_rate as f64)
            .tan() as f32;
        for stage in 0..STAGES {
            let k = 1.0 / BUTTERWORTH_Q[stage];
            let a1 = 1.0 / (1.0 + g * (g + k));
            self.high_a1[stage] = a1;
            self.high_a2[stage] = g * a1;
            self.high_a3[stage] = g * (g * a1);
            self.high_k[stage] = k;
        }
    }

    fn low_pass(&mut self, channel: usize, input: f32) -> f32 {
        let mut value = input;
        for stage in 0..STAGES {
            let i = (channel * STAGES + stage) * 2;
            let ic1 = self.low_state[i];
            let ic2 = self.low_state[i + 1];
            let v3 = value - ic2;
            let v1 = self.low_a1[stage] * ic1 + self.low_a2[stage] * v3;
            let v2 = ic2 + self.low_a2[stage] * ic1 + self.low_a3[stage] * v3;
            self.low_state[i] = 2.0 * v1 - ic1;
            self.low_state[i + 1] = 2.0 * v2 - ic2;
            value = v2;
        }
        value
    }

    fn high_pass(&mut self, channel: usize, input: f32) -> f32 {
        let mut value = input;
        for stage in 0..STAGES {
            let i = (channel * STAGES + stage) * 2;
            let ic1 = self.high_state[i];
            let ic2 = self.high_state[i + 1];
            let v3 = value - ic2;
            let v1 = self.high_a1[stage] * ic1 + self.high_a2[stage] * v3;
            let v2 = ic2 + self.high_a2[stage] * ic1 + self.high_a3[stage] * v3;
            self.high_state[i] = 2.0 * v1 - ic1;
            self.high_state[i + 1] = 2.0 * v2 - ic2;
            value -= self.high_k[stage] * v1 + v2;
        }
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, rate: u32, frames: usize) -> Vec<f32> {
        (0..frames * 2)
            .map(|i| {
                let t = (i / 2) as f32 / rate as f32;
                (2.0 * core::f32::consts::PI * freq * t).sin() * 0.5
            })
            .collect()
    }

    fn rms(buf: &[f32]) -> f32 {
        (buf.iter().map(|v| v * v).sum::<f32>() / buf.len() as f32).sqrt()
    }

    #[test]
    fn parked_state_is_an_exact_buffer_copy() {
        let mut filter = TransitionFilter::new(2, 48_000);
        let input = sine(1000.0, 48_000, 1024);
        let mut buf = input.clone();
        filter.process(&mut buf);
        assert_eq!(buf, input);
    }

    #[test]
    fn low_pass_attenuates_above_cutoff_and_passes_below() {
        let mut filter = TransitionFilter::new(2, 48_000);
        // 24 dB/oct at cutoff: a tone at 8× cutoff should be crushed.
        filter.set_cutoffs(500.0, OFF_HZ);
        // Prime the glide to land at the target before measuring.
        for _ in 0..200 {
            let mut warm = sine(4000.0, 48_000, 64);
            filter.process(&mut warm);
        }
        let mut high = sine(4000.0, 48_000, 4096);
        filter.process(&mut high);
        let high_rms = rms(&high);

        filter.flush();
        filter.set_cutoffs(OPEN_HZ, OFF_HZ);
        for _ in 0..200 {
            let mut warm = sine(250.0, 48_000, 64);
            filter.process(&mut warm);
        }
        let mut low = sine(250.0, 48_000, 4096);
        filter.process(&mut low);
        let low_rms = rms(&low);

        // 4 kHz through a 500 Hz 4th-order LP: ≈ (4000/500)^-4.8 magnitude
        // vs the 250 Hz tone well inside the passband.
        assert!(
            low_rms > high_rms * 20.0,
            "passband {low_rms} should far exceed stopband {high_rms}"
        );
    }

    #[test]
    fn geometric_glide_travels_monotonically_toward_target() {
        let mut filter = TransitionFilter::new(2, 48_000);
        filter.flush();
        filter.set_cutoffs(1_000.0, OFF_HZ);
        // The private current cutoff is observable through behaviour: drive
        // single 64-frame blocks with the parked detection defeated by a
        // target below open — the glide must never jump discontinuously to
        // the target (that is the zipper-noise failure the glide exists to
        // prevent). Feed a block right after aiming and confirm it was
        // filtered (current cutoff still below 20000 - SETTLED after one
        // 30 ms-scale glide step).
        let mut block = sine(100.0, 48_000, 64);
        let before = block.clone();
        filter.process(&mut block);
        // After one GLIDE step from 20 kHz, the cutoff is far above 1 kHz, so
        // attenuation on a 100 Hz tone is negligible — but the parked
        // short-circuit must NOT have fired, i.e. state must have advanced.
        assert!(filter.current_low_pass_hz < OPEN_HZ - SETTLED_HZ);
        assert!(filter.current_low_pass_hz > 1_000.0);
        assert_ne!(block, before);
    }
}

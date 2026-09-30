//! Lastwave Reference acoustic contour, derived from ec11a43 (GPL-3.0).
//! Float headroom is retained until the shared output protector.
use std::collections::VecDeque;
use std::f64::consts::PI;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SoundMode {
    Transparent,
    Enhanced,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClarityPreset {
    Reference,
    Speaker,
    Headphone,
    Dac,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoudnessMode {
    Off,
    Track,
    Album,
}
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClarityTuning {
    pub preset: ClarityPreset,
    pub wet: f32,
    pub trims_db: Vec<f32>,
}
impl Default for ClarityTuning {
    fn default() -> Self {
        Self {
            preset: ClarityPreset::Reference,
            wet: 1.0,
            trims_db: vec![0.0; 8],
        }
    }
}
impl ClarityTuning {
    fn trims(&self) -> [f64; 8] {
        let mut t = match self.preset {
            ClarityPreset::Reference => [0.0; 8],
            ClarityPreset::Speaker => [0.0, -1.5, 0.0, 0.0, 0.0, -0.5, 0.0, 0.0],
            ClarityPreset::Headphone => [0.0, -0.5, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0],
            ClarityPreset::Dac => [0.0, 0.0, 0.0, 0.0, 0.0, -1.5, 0.0, -1.0],
        };
        for (i, v) in self.trims_db.iter().take(8).enumerate() {
            if v.is_finite() {
                t[i] = (t[i] + *v as f64).clamp(-12.0, 12.0);
            }
        }
        t
    }
}
/// An explicitly identified EBU R128/BS.1770 measurement. Never construct this
/// from YouTube's relative loudness field or a ReplayGain gain tag.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LoudnessMeasurement {
    pub track_lufs: f64,
    pub album_lufs: Option<f64>,
    pub true_peak_dbtp: Option<f64>,
}
impl LoudnessMeasurement {
    pub fn gain_db(&self, mode: LoudnessMode) -> Option<f64> {
        if mode == LoudnessMode::Off {
            return None;
        }
        let measured = if mode == LoudnessMode::Album {
            self.album_lufs.unwrap_or(self.track_lufs)
        } else {
            self.track_lufs
        };
        if !measured.is_finite() || !(-100.0..=10.0).contains(&measured) {
            return None;
        }
        let mut gain = (-14.0 - measured).clamp(-15.0, 15.0);
        if let Some(peak) = self.true_peak_dbtp.filter(|p| p.is_finite()) {
            gain = gain.min(-0.5 - peak);
        }
        Some(gain)
    }
}
#[derive(Clone)]
struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    z: [[f64; 2]; 2],
}
impl Biquad {
    fn normalized(b: [f64; 3], a: [f64; 3]) -> Self {
        Self {
            b: b.map(|v| v / a[0]),
            a: [a[1] / a[0], a[2] / a[0]],
            z: [[0.0; 2]; 2],
        }
    }
    fn hp(rate: f64, hz: f64, q: f64) -> Self {
        let w = 2.0 * PI * hz.min(rate * 0.45) / rate;
        let c = w.cos();
        let alpha = w.sin() / (2.0 * q);
        Self::normalized(
            [(1.0 + c) * 0.5, -(1.0 + c), (1.0 + c) * 0.5],
            [1.0 + alpha, -2.0 * c, 1.0 - alpha],
        )
    }
    fn bell(rate: f64, hz: f64, q: f64, db: f64) -> Self {
        let w = 2.0 * PI * hz.min(rate * 0.45) / rate;
        let c = w.cos();
        let alpha = w.sin() / (2.0 * q);
        let amp = 10f64.powf(db / 40.0);
        Self::normalized(
            [1.0 + alpha * amp, -2.0 * c, 1.0 - alpha * amp],
            [1.0 + alpha / amp, -2.0 * c, 1.0 - alpha / amp],
        )
    }
    fn shelf(rate: f64, hz: f64, slope: f64, db: f64) -> Self {
        let w = 2.0 * PI * hz.min(rate * 0.45) / rate;
        let c = w.cos();
        let amp = 10f64.powf(db / 40.0);
        let alpha = w.sin() * 0.5 * ((amp + 1.0 / amp) * (1.0 / slope - 1.0) + 2.0).sqrt();
        let beta = 2.0 * amp.sqrt() * alpha;
        Self::normalized(
            [
                amp * ((amp + 1.0) + (amp - 1.0) * c + beta),
                -2.0 * amp * ((amp - 1.0) + (amp + 1.0) * c),
                amp * ((amp + 1.0) + (amp - 1.0) * c - beta),
            ],
            [
                (amp + 1.0) - (amp - 1.0) * c + beta,
                2.0 * ((amp - 1.0) - (amp + 1.0) * c),
                (amp + 1.0) - (amp - 1.0) * c - beta,
            ],
        )
    }
    fn tick(&mut self, x: f64, ch: usize) -> f64 {
        let y = self.b[0] * x + self.z[ch][0];
        self.z[ch][0] = self.b[1] * x - self.a[0] * y + self.z[ch][1];
        self.z[ch][1] = self.b[2] * x - self.a[1] * y;
        y
    }
}
// 4x interpolation/decimation FIR: fixed 16-frame latency each way. The
// nonlinear exciter runs between the two filters, never at the device rate.
const TAPS: usize = 129;
#[derive(Clone)]
struct Fir {
    taps: [f64; TAPS],
    history: [[f64; 2]; TAPS * 2],
    cursor: usize,
}
fn bessel(x: f64) -> f64 {
    let (mut sum, mut term) = (1.0, 1.0);
    for k in 1..40 {
        term *= x * x / (4.0 * (k * k) as f64);
        sum += term;
    }
    sum
}
impl Fir {
    fn new() -> Self {
        let mut taps = [0.0; TAPS];
        let denom = bessel(10.0);
        for (i, t) in taps.iter_mut().enumerate() {
            let n = i as f64 - 64.0;
            let sinc = if n == 0.0 {
                0.25
            } else {
                (PI * 0.25 * n).sin() / (PI * n)
            };
            let win = bessel(10.0 * (1.0 - (n / 64.0).powi(2)).max(0.0).sqrt()) / denom;
            *t = sinc * win;
        }
        let sum: f64 = taps.iter().sum();
        for t in &mut taps {
            *t /= sum;
        }
        Self {
            taps,
            history: [[0.0; 2]; TAPS * 2],
            cursor: 0,
        }
    }
    fn push(&mut self, x: [f64; 2]) {
        self.history[self.cursor] = x;
        self.history[self.cursor + TAPS] = x;
        self.cursor += 1;
        if self.cursor == TAPS {
            self.cursor = 0;
        }
    }
    fn tick(&mut self, x: [f64; 2]) -> [f64; 2] {
        self.push(x);
        let mut y = [0.0; 2];
        // Duplicated circular history permits contiguous reverse traversal,
        // retaining the original summation order without per-tap modulo.
        for (s, t) in self.history[self.cursor..self.cursor + TAPS]
            .iter()
            .rev()
            .zip(&self.taps)
        {
            y[0] += s[0] * t;
            y[1] += s[1] * t;
        }
        y
    }
}
// Polyphase interpolation skips the known inserted zeros. This evaluates the
// same FIR in the same nonzero-term order, with 33 rather than 129 input slots.
#[derive(Clone)]
struct Interpolator {
    taps: [f64; TAPS],
    history: [[f64; 2]; 66],
    cursor: usize,
}
impl Interpolator {
    fn new() -> Self {
        Self {
            taps: Fir::new().taps,
            history: [[0.0; 2]; 66],
            cursor: 0,
        }
    }
    fn frame(&mut self, x: [f64; 2]) -> [[f64; 2]; 4] {
        let x = x.map(|v| v * 4.0);
        self.history[self.cursor] = x;
        self.history[self.cursor + 33] = x;
        self.cursor += 1;
        if self.cursor == 33 {
            self.cursor = 0;
        }
        let mut output = [[0.0; 2]; 4];
        for phase in 0..4 {
            for (s, t) in self.history[self.cursor..self.cursor + 33]
                .iter()
                .rev()
                .zip(self.taps.iter().skip(phase).step_by(4))
            {
                output[phase][0] += s[0] * t;
                output[phase][1] += s[1] * t;
            }
        }
        output
    }
}
pub struct Clarity {
    rate: u32,
    mode: SoundMode,
    tuning: ClarityTuning,
    wet: f64,
    filters: [Biquad; 6],
    side: Biquad,
    air: Biquad,
    up: Interpolator,
    down: Fir,
    delay: VecDeque<[f64; 2]>,
    dry_delay: VecDeque<[f64; 2]>,
    trims: [f64; 8],
    ticks: usize,
    dc: [[f64; 2]; 2],
}
impl Clarity {
    pub fn new(rate: u32) -> Self {
        let r = rate as f64;
        Self {
            rate,
            mode: SoundMode::Transparent,
            tuning: ClarityTuning::default(),
            wet: 0.0,
            filters: [
                Biquad::hp(r, 24.0, 0.7071067811865476),
                Biquad::bell(r, 72.0, 0.8, 3.2),
                Biquad::bell(r, 280.0, 0.9, -3.0),
                Biquad::bell(r, 750.0, 0.85, -1.4),
                Biquad::bell(r, 3400.0, 0.85, 3.8),
                Biquad::shelf(r, 10500.0, 0.85, 4.8),
            ],
            side: Biquad::hp(r, 130.0, 0.7071067811865476),
            air: Biquad::hp(r * 4.0, 6000.0, 0.7071067811865476),
            up: Interpolator::new(),
            down: Fir::new(),
            delay: VecDeque::from(vec![[0.0; 2]; 32]),
            dry_delay: VecDeque::from(vec![[0.0; 2]; 32]),
            trims: [0.0; 8],
            ticks: 0,
            dc: [[0.0; 2]; 2],
        }
    }
    pub fn set(&mut self, mode: SoundMode, tuning: ClarityTuning) {
        self.mode = mode;
        self.tuning = tuning;
    }
    pub fn active(&self) -> bool {
        self.mode == SoundMode::Enhanced || self.wet > 0.0
    }
    pub fn reset(&mut self) {
        let mode = self.mode;
        let tuning = self.tuning.clone();
        *self = Self::new(self.rate);
        self.set(mode, tuning);
    }
    pub fn retarget(&mut self, rate: u32) {
        self.rate = rate;
        self.reset();
    }
    pub fn delay_frames(&self) -> u32 {
        if self.active() {
            32
        } else {
            0
        }
    }
    fn update_coefficients(&mut self) {
        let target = self.tuning.trims();
        let alpha = 1.0 - (-128.0 / (self.rate as f64 * 0.010)).exp();
        for (v, t) in self.trims.iter_mut().zip(target) {
            *v += (t - *v) * alpha;
        }
        // Preserve histories during live tuning. Coefficients, not state, move.
        let r = self.rate as f64;
        let specs = [
            Biquad::hp(r, 24.0, 0.7071067811865476),
            Biquad::bell(r, 72.0, 0.8, 3.2 + self.trims[1]),
            Biquad::bell(r, 280.0, 0.9, -3.0 + self.trims[2]),
            Biquad::bell(r, 750.0, 0.85, -1.4 + self.trims[3]),
            Biquad::bell(r, 3400.0, 0.85, 3.8 + self.trims[4]),
            Biquad::shelf(r, 10500.0, 0.85, 4.8 + self.trims[5]),
        ];
        for (f, s) in self.filters.iter_mut().zip(specs) {
            f.b = s.b;
            f.a = s.a;
        }
    }
    pub fn process(&mut self, samples: &mut [f32]) {
        if !self.active() {
            return;
        }
        let dc_pole = (-2.0 * PI * 10.0 / self.rate as f64).exp();
        for frame in samples.chunks_exact_mut(2) {
            if self.ticks % 128 == 0 {
                self.update_coefficients();
            }
            self.ticks += 1;
            let target = if self.mode == SoundMode::Enhanced {
                if self.tuning.wet.is_finite() {
                    self.tuning.wet.clamp(0.0, 1.0) as f64
                } else {
                    1.0
                }
            } else {
                0.0
            };
            self.wet += (target - self.wet).clamp(
                -1.0 / (self.rate as f64 * 0.05),
                1.0 / (self.rate as f64 * 0.05),
            );
            let mut dry = [frame[0] as f64, frame[1] as f64];
            for ch in 0..2 {
                let x = dry[ch];
                let y = x - self.dc[ch][0] + dc_pole * self.dc[ch][1];
                self.dc[ch] = [x, y];
                dry[ch] = y;
            }
            let mut wet = dry;
            for ch in 0..2 {
                wet[ch] = self.filters[0].tick(wet[ch], ch) * 10f64.powf(self.trims[0] / 20.0);
                for f in &mut self.filters[1..] {
                    wet[ch] = f.tick(wet[ch], ch);
                }
            }
            self.delay.push_back(wet);
            wet = self.delay.pop_front().unwrap();
            let mut excited = [0.0; 2];
            for (phase, up) in self.up.frame(dry).into_iter().enumerate() {
                let mut nonlinear = [0.0; 2];
                for ch in 0..2 {
                    let x = self.air.tick(up[ch], ch);
                    nonlinear[ch] = x - 0.25 * x * x * x;
                }
                if phase == 0 {
                    excited = self.down.tick(nonlinear);
                } else {
                    // Decimation consumes all phases but needs one FIR result.
                    self.down.push(nonlinear);
                }
            }
            for ch in 0..2 {
                wet[ch] += excited[ch] * 0.18 * 10f64.powf(self.trims[7] / 20.0);
            }
            let mid = (wet[0] + wet[1]) * 0.5;
            let side = self.side.tick((wet[0] - wet[1]) * 0.5, 0)
                * 1.22
                * 10f64.powf(self.trims[6] / 20.0);
            wet = [(mid + side) * 1.04, (mid - side) * 1.04];
            // Match latency in wet and dry branches; partial wet must not
            // introduce a 32-frame comb filter into an otherwise flat signal.
            self.dry_delay.push_back(dry);
            let dry = self.dry_delay.pop_front().unwrap();
            for ch in 0..2 {
                frame[ch] = (dry[ch] + (wet[ch] - dry[ch]) * self.wet) as f32;
            }
        }
    }
}
struct QueuedFrame {
    samples: [f32; 2],
    bound: f64,
}
/// Stereo-linked lookahead. A future overload lays down a gain ramp across
/// queued samples; release persists across arbitrary render block boundaries.
pub struct Protector {
    rate: u32,
    queue: VecDeque<QueuedFrame>,
    detector: Interpolator,
    gain: f64,
    release: f64,
    lookahead_release: f64,
    pub reduction_db: f32,
    pub interventions: u64,
}
impl Protector {
    pub fn new(rate: u32) -> Self {
        Self {
            rate,
            queue: VecDeque::with_capacity(rate as usize / 200 + 34),
            detector: Interpolator::new(),
            gain: 1.0,
            release: (-1.0 / (rate as f64 * 0.150)).exp(),
            lookahead_release: (-((rate as usize / 200 + 33) as f64) / (rate as f64 * 0.150)).exp(),
            reduction_db: 0.0,
            interventions: 0,
        }
    }
    pub fn delay_frames(&self) -> usize {
        self.rate as usize / 200 + 32
    }
    pub fn reset(&mut self) {
        *self = Self::new(self.rate);
    }
    pub fn process(&mut self, samples: &mut [f32], enhanced: bool) {
        let ceiling = if enhanced {
            10f64.powf(-0.5 / 20.0)
        } else {
            1.0
        };
        for f in samples.chunks_exact_mut(2) {
            for s in f.iter_mut() {
                if !s.is_finite() {
                    *s = 0.0;
                    self.interventions += 1;
                }
            }
            if !enhanced {
                self.reduction_db = 0.0;
                for s in f.iter_mut() {
                    if s.abs() > 1.0 {
                        self.interventions += 1;
                        *s = s.clamp(-1.0, 1.0);
                    }
                }
                continue;
            }
            self.queue.push_back(QueuedFrame {
                samples: [f[0], f[1]],
                bound: 1.0,
            });
            let mut peak = f[0].abs().max(f[1].abs()) as f64;
            for y in self.detector.frame([f[0] as f64, f[1] as f64]) {
                peak = peak.max(y[0].abs()).max(y[1].abs());
            }
            if peak > ceiling {
                self.interventions += 1; // Reserve 0.51 dB for reconstruction and the changing gain envelope.
                let target = (ceiling / peak / 1.06).min(1.0);
                let n = self.queue.len();
                let attack = (self.rate as usize / 200).max(1);
                // No queued sample can exceed the unconstrained release
                // envelope. Skip ramps that cannot bind any future output;
                // this preserves samples while avoiding O(lookahead) work for
                // every already-protected peak in a hot master.
                let projected_gain = 1.0 - (1.0 - self.gain) * self.lookahead_release;
                if projected_gain > target {
                    for (i, q) in self.queue.iter_mut().enumerate() {
                        let distance = n - 1 - i;
                        let bound = if distance <= 32 {
                            target
                        } else {
                            (target + (1.0 - target) * (distance - 32) as f64 / attack as f64)
                                .min(1.0)
                        };
                        q.bound = q.bound.min(bound);
                    }
                }
            }
            if self.queue.len() > self.delay_frames() {
                let q = self.queue.pop_front().unwrap();
                self.gain = (1.0 - (1.0 - self.gain) * self.release).min(q.bound);
                self.reduction_db = (-20.0 * self.gain.max(1e-12).log10()) as f32;
                f[0] = (q.samples[0] as f64 * self.gain) as f32;
                f[1] = (q.samples[1] as f64 * self.gain) as f32;
            } else {
                f.fill(0.0);
            }
            for s in f.iter_mut() {
                if s.abs() > ceiling as f32 {
                    self.interventions += 1;
                    *s = s.clamp(-ceiling as f32, ceiling as f32);
                }
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn polyphase_matches_zero_inserted_fir() {
        let mut reference = Fir::new();
        let mut polyphase = Interpolator::new();
        for i in 0..5000 {
            let input = [(i as f64 * 0.173).sin(), (i as f64 * 0.093).cos() * 1.7];
            let actual = polyphase.frame(input);
            for phase in 0..4 {
                let expected = reference.tick(if phase == 0 {
                    input.map(|v| v * 4.0)
                } else {
                    [0.0; 2]
                });
                assert_eq!(actual[phase], expected);
            }
        }
    }
    #[test]
    fn transparent_exact_and_headroom_reported() {
        let mut c = Clarity::new(48000);
        let mut p = Protector::new(48000);
        let input = vec![0.1, -0.9, 0.999, -0.0];
        let mut x = input.clone();
        c.process(&mut x);
        p.process(&mut x, false);
        assert_eq!(x, input);
        p.process(&mut [1.5, -1.5, f32::NAN, 0.0], false);
        assert_eq!(p.interventions, 3);
    }
    #[test]
    fn protection_independent_of_partition() {
        let src: Vec<f32> = (0..20000).map(|i| (i as f32 * 0.071).sin() * 2.2).collect();
        let render = |n| {
            let mut p = Protector::new(48000);
            let mut x = src.clone();
            for b in x.chunks_mut(n) {
                p.process(b, true);
            }
            x
        };
        assert_eq!(render(1024), render(74));
        assert!(render(74)
            .iter()
            .all(|x| x.abs() <= 10f32.powf(-0.5 / 20.0)));
    }
    #[test]
    fn enhanced_finite_hot_input() {
        let mut c = Clarity::new(48000);
        c.set(SoundMode::Enhanced, ClarityTuning::default());
        let mut p = Protector::new(48000);
        let mut x: Vec<f32> = (0..20000).map(|i| (i as f32 * 0.173).sin() * 3.0).collect();
        c.process(&mut x);
        p.process(&mut x, true);
        assert!(x.iter().all(|x| x.is_finite() && x.abs() <= 0.9441));
    }
    #[test]
    fn protected_true_peak_is_below_ceiling() {
        for rate in [44100, 48000] {
            for frequency in [1000.0, 10000.0, 19000.0] {
                let mut p = Protector::new(rate);
                let mut x: Vec<f32> = (0..rate)
                    .flat_map(|i| {
                        let s = (2.0 * PI * frequency * i as f64 / rate as f64 + 0.4).sin() as f32
                            * 1.6;
                        [s, -s * 0.73]
                    })
                    .collect();
                p.process(&mut x, true);
                let mut tail = vec![0.0; p.delay_frames() * 2];
                p.process(&mut tail, true);
                x.extend(tail);
                let mut r = crate::decode::resampler::StreamResampler::stereo(rate, rate * 4);
                let mut oversampled = r.process(&x);
                oversampled.extend(r.flush());
                let peak = oversampled.iter().map(|v| v.abs()).fold(0f32, f32::max);
                assert!(
                    peak <= 10f32.powf(-0.5 / 20.0) + 1e-4,
                    "{rate} / {frequency}: {peak}"
                );
            }
        }
    }
}

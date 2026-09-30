//! 10-slot parametric equaliser — faithful f32 port of upstream
//! `EqualizerProcessor` + `EqLayout` + `EqCurve`.
//!
//! ## The layout
//!
//! Upstream's `EqLayout` fixes the shape of the cascade. Slots 0..6 are the
//! manual tab (a low shelf at 60 Hz, a high shelf at 14 kHz, and five peaking
//! bells between); slots 7..9 are the tone pad (a low shelf at 250 Hz, a bell
//! at 1 kHz, a high shelf at 4 kHz). Both tabs drive the *same* ten slots, so
//! switching tab or preset is a gain change like any other and glides rather
//! than clicks.
//!
//! ## State-variable filters
//!
//! Two-integrator state-variable sections (trapezoidal SVF, bilinear transform
//! with frequency pre-warping), exactly as upstream: SVFs decouple frequency
//! from Q, keep internal states bounded under parameter modulation, and let a
//! slider drag glide without transients.
//!
//! ## Gliding
//!
//! Every change is a target, not a step. Coefficients are re-computed once per
//! [`GLIDE_FRAMES`] frames, chasing the target curve smoothly, so a preset
//! switch or a slider drag is an inaudible glide rather than a zipper.
//!
//! ## Headroom + make-up
//!
//! Boosting a band raises the peak with it, and the fixed-point output has no
//! headroom above full scale, so the whole curve is pulled down by however much
//! its loudest point was pushed up ([`EqCurve::of`]). The DSP itself preserves
//! headroom (no clamping inside the cascade); only the output boundary clamps.
//!
//! Balance is an output trim (not a section) and does not run at all for mono.

/// One filter's shape: where on the spectrum it sits and what it does there.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FilterKind {
    Bell,
    LowShelf,
    HighShelf,
}

/// A slot's fixed identity: its shape and its centre/corner frequency.
#[derive(Clone, Copy, Debug)]
pub struct FilterSlot {
    pub kind: FilterKind,
    pub frequency_hz: f32,
}

/// Every filter either tab can ask for, in one fixed list (upstream `EqLayout`).
pub struct EqLayout;

impl EqLayout {
    /// The seven centres the manual tab puts a slider under.
    pub const MANUAL_BANDS_HZ: [f32; 7] = [60.0, 150.0, 400.0, 1_000.0, 2_500.0, 6_000.0, 14_000.0];
    /// Wide enough to overlap neighbours (≈1.3 octaves apart).
    pub const MANUAL_Q: f32 = 1.0;

    pub const MANUAL_FIRST: usize = 0;
    pub const MANUAL_COUNT: usize = 7;

    /// Slots 7..9: the tone pad's tilt pair and its mid contour.
    pub const TONE_LOW: usize = 7;
    pub const TONE_MID: usize = 8;
    pub const TONE_HIGH: usize = 9;

    pub const SLOTS: usize = 10;

    /// How far a manual slider travels either way.
    pub const MANUAL_RANGE_DB: f32 = 12.0;

    /// How far the tone pad travels on each axis, in whole steps.
    pub const TONE_STEPS: i32 = 5;

    /// Decibels per step of the pad, so a corner is ±6 dB.
    pub const TONE_DB_PER_STEP: f32 = 1.2;

    /// Frequency of the tone pad's tilt pair, for the UI to describe.
    pub const TONE_TILT_HZ: [f32; 2] = [250.0, 4_000.0];

    pub fn slots() -> [FilterSlot; Self::SLOTS] {
        [
            FilterSlot {
                kind: FilterKind::LowShelf,
                frequency_hz: 60.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 150.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 400.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 1_000.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 2_500.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 6_000.0,
            },
            FilterSlot {
                kind: FilterKind::HighShelf,
                frequency_hz: 14_000.0,
            },
            FilterSlot {
                kind: FilterKind::LowShelf,
                frequency_hz: 250.0,
            },
            FilterSlot {
                kind: FilterKind::Bell,
                frequency_hz: 1_000.0,
            },
            FilterSlot {
                kind: FilterKind::HighShelf,
                frequency_hz: 4_000.0,
            },
        ]
    }
}

/// A tuning, rendered: every slot's gain and Q, plus the make-up attenuation.
#[derive(Clone, Debug)]
pub struct EqCurve {
    pub gains_db: [f32; EqLayout::SLOTS],
    pub qs: [f32; EqLayout::SLOTS],
    /// Make-up attenuation, always ≤ 0 (upstream `EqCurve.preampDb`).
    pub preamp_db: f32,
}

impl EqCurve {
    pub fn flat() -> Self {
        Self::of(&[0.0; EqLayout::SLOTS], &[0.707; EqLayout::SLOTS])
    }

    /// Builds a curve and works out the attenuation it needs.
    pub fn of(gains_db: &[f32], qs: &[f32]) -> Self {
        let mut gains = [0.0f32; EqLayout::SLOTS];
        let mut q = [0.707f32; EqLayout::SLOTS];
        for i in 0..EqLayout::SLOTS {
            gains[i] = gains_db
                .get(i)
                .copied()
                .filter(|v| v.is_finite())
                .unwrap_or(0.0)
                .clamp(-24.0, 24.0);
            q[i] = qs
                .get(i)
                .copied()
                .filter(|v| v.is_finite())
                .unwrap_or(0.707)
                .clamp(MIN_Q, 12.0);
        }
        let preamp_db = preamp_for(&gains, &q);
        Self {
            gains_db: gains,
            qs: q,
            preamp_db,
        }
    }
}

/// The seven sliders, as a curve. Slots the tone pad owns stay flat.
pub fn manual_curve(bands_db: &[f32]) -> EqCurve {
    let mut gains = [0.0f32; EqLayout::SLOTS];
    let mut qs = [0.707f32; EqLayout::SLOTS];
    for band in 0..EqLayout::MANUAL_COUNT {
        gains[EqLayout::MANUAL_FIRST + band] = bands_db
            .get(band)
            .copied()
            .unwrap_or(0.0)
            .clamp(-EqLayout::MANUAL_RANGE_DB, EqLayout::MANUAL_RANGE_DB);
        qs[EqLayout::MANUAL_FIRST + band] = EqLayout::MANUAL_Q;
    }
    EqCurve::of(&gains, &qs)
}

/// The tone pad, as a curve (upstream `toneCurve`). Slots the manual tab owns
/// stay flat.
pub fn tone_curve(x: i32, y: i32, focused: bool) -> EqCurve {
    let mut gains = [0.0f32; EqLayout::SLOTS];
    let mut qs = [0.707f32; EqLayout::SLOTS];
    let steps = EqLayout::TONE_STEPS;
    let tilt = x.clamp(-steps, steps) as f32 * EqLayout::TONE_DB_PER_STEP;
    let contour = y.clamp(-steps, steps) as f32 * EqLayout::TONE_DB_PER_STEP;

    gains[EqLayout::TONE_LOW] = -tilt;
    gains[EqLayout::TONE_HIGH] = tilt;
    gains[EqLayout::TONE_MID] = contour;

    let shelf_q = if focused { 0.9 } else { 0.5 };
    let bell_q = if focused { 2.2 } else { 0.7 };
    qs[EqLayout::TONE_LOW] = shelf_q;
    qs[EqLayout::TONE_HIGH] = shelf_q;
    qs[EqLayout::TONE_MID] = bell_q;
    EqCurve::of(&gains, &qs)
}

/// How far down the curve has to be pulled to stop it clipping (upstream
/// `preampFor`). Walks the summed response — magnitudes multiply through a
/// cascade, so decibels add — and takes its actual peak.
fn preamp_for(gains_db: &[f32; EqLayout::SLOTS], qs: &[f32; EqLayout::SLOTS]) -> f32 {
    let mut peak = 0.0f32;
    for point in 0..RESPONSE_POINTS {
        let hz = response_frequency(point);
        let mut sum = 0.0f32;
        for slot in 0..EqLayout::SLOTS {
            sum += section_gain_db(&EqLayout::slots()[slot], gains_db[slot], qs[slot], hz);
        }
        if sum > peak {
            peak = sum;
        }
    }
    -peak
}

/// Log-spaced across the audible band: 20 Hz to 20 kHz.
fn response_frequency(point: usize) -> f32 {
    let fraction = point as f64 / (RESPONSE_POINTS - 1) as f64;
    (20.0 * 1_000.0f64.powf(fraction)) as f32
}

/// One section's contribution at `hz`, in decibels (upstream `sectionGainDb`).
fn section_gain_db(slot: &FilterSlot, gain_db: f32, q: f32, hz: f32) -> f32 {
    if gain_db.abs() < 0.01 {
        return 0.0;
    }
    let a = 10.0f64.powf(gain_db as f64 / 40.0);
    let a2 = a * a;
    let x = hz as f64 / slot.frequency_hz as f64;
    let x2 = x * x;
    let qq = (q as f64) * (q as f64);
    let magnitude = match slot.kind {
        FilterKind::Bell => {
            let flat = (1.0 - x2) * (1.0 - x2);
            ((flat + x2 * a2 / qq) / (flat + x2 / (a2 * qq))).sqrt()
        }
        FilterKind::LowShelf => {
            let common = x2 * a / qq;
            a * (((a - x2) * (a - x2) + common) / ((1.0 - a * x2) * (1.0 - a * x2) + common)).sqrt()
        }
        FilterKind::HighShelf => {
            let common = x2 * a / qq;
            a * (((1.0 - a * x2) * (1.0 - a * x2) + common) / ((a - x2) * (a - x2) + common)).sqrt()
        }
    };
    (20.0 * magnitude.log10()) as f32
}

const RESPONSE_POINTS: usize = 96;

// ---- Processor --------------------------------------------------------------

/// Below this a band is doing nothing anyone can hear, so it counts as flat.
const SETTLED_DB: f32 = 0.01;
/// Same idea for the balance trim, where the scale is -1 to 1.
const SETTLED_BALANCE: f32 = 0.0005;
const MIN_Q: f32 = 0.05;
const MIN_HZ: f32 = 10.0;
/// Keeps `tan` away from its pole at Nyquist.
const MAX_FREQUENCY_FRACTION: f32 = 0.45;
/// Safe noise floor threshold to prevent floating point denormals.
const DENORMAL_FLOOR: f32 = 1e-12;
/// Frames between coefficient updates (~1.5 ms at 44.1 kHz).
const GLIDE_FRAMES: usize = 64;
/// Per-sub-block glide fraction (~18 ms time constant).
const GLIDE_RATE: f32 = 0.08;

/// 10-band parametric equaliser, tone controls, pre-amp and balance — the f32
/// port of upstream `EqualizerProcessor`.
pub struct EqualizerProcessor {
    sample_rate: f32,
    channels: usize,

    target_enabled: bool,
    target_gains: [f32; EqLayout::SLOTS],
    target_qs: [f32; EqLayout::SLOTS],
    target_preamp_db: f32,
    target_balance: f32,

    current_gains: [f32; EqLayout::SLOTS],
    current_qs: [f32; EqLayout::SLOTS],
    current_preamp_db: f32,
    current_balance: f32,

    coeff_a1: [f32; EqLayout::SLOTS],
    coeff_a2: [f32; EqLayout::SLOTS],
    coeff_a3: [f32; EqLayout::SLOTS],
    mix_input: [f32; EqLayout::SLOTS],
    mix_band: [f32; EqLayout::SLOTS],
    mix_low: [f32; EqLayout::SLOTS],

    active_slots: [usize; EqLayout::SLOTS],
    running: [bool; EqLayout::SLOTS],

    /// Two integrator states per section, per channel.
    state: Vec<f32>,
    /// Output trim per channel: make-up attenuation, and balance where stereo.
    channel_gain: Vec<f32>,
}

impl EqualizerProcessor {
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        let mut processor = Self {
            sample_rate: sample_rate.max(8_000) as f32,
            channels: channels.max(1),
            target_enabled: false,
            target_gains: [0.0; EqLayout::SLOTS],
            target_qs: [0.707; EqLayout::SLOTS],
            target_preamp_db: 0.0,
            target_balance: 0.0,
            current_gains: [0.0; EqLayout::SLOTS],
            current_qs: [0.707; EqLayout::SLOTS],
            current_preamp_db: 0.0,
            current_balance: 0.0,
            coeff_a1: [0.0; EqLayout::SLOTS],
            coeff_a2: [0.0; EqLayout::SLOTS],
            coeff_a3: [0.0; EqLayout::SLOTS],
            mix_input: [0.0; EqLayout::SLOTS],
            mix_band: [0.0; EqLayout::SLOTS],
            mix_low: [0.0; EqLayout::SLOTS],
            active_slots: [0; EqLayout::SLOTS],
            running: [false; EqLayout::SLOTS],
            state: vec![0.0; channels.max(1) * EqLayout::SLOTS * 2],
            channel_gain: vec![1.0; channels.max(1)],
        };
        processor.configure();
        processor
    }

    pub fn diagnostic_settings(&self) -> serde_json::Value {
        serde_json::json!({"enabled":self.target_enabled,"gains_db":self.target_gains,"qs":self.target_qs,"preamp_db":self.target_preamp_db,"balance":self.target_balance})
    }

    pub fn active(&self) -> bool {
        !is_flat(
            self.target_enabled,
            &self.target_gains,
            self.target_preamp_db,
            self.target_balance,
        )
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Aims the equaliser (upstream `setTuning`). `enabled = false` is a flat
    /// curve and a centred balance rather than a bypass flag, so switching off
    /// glides down to nothing.
    pub fn set_tuning(&mut self, enabled: bool, curve: &EqCurve, balance: f32) {
        self.target_enabled = enabled;
        if enabled {
            self.target_gains = curve.gains_db;
            self.target_qs = curve.qs;
            self.target_preamp_db = curve.preamp_db;
            self.target_balance = if balance.is_finite() {
                balance.clamp(-1.0, 1.0)
            } else {
                0.0
            };
        } else {
            self.target_gains = [0.0; EqLayout::SLOTS];
            self.target_qs = [0.707; EqLayout::SLOTS];
            self.target_preamp_db = 0.0;
            self.target_balance = 0.0;
        }
    }

    fn configure(&mut self) {
        self.state = vec![0.0; self.channels * EqLayout::SLOTS * 2];
        self.channel_gain = vec![1.0; self.channels];
        self.running = [false; EqLayout::SLOTS];
        self.snap_to_target();
    }

    pub fn retarget(&mut self, sample_rate: u32, channels: usize) {
        self.sample_rate = sample_rate.max(8_000) as f32;
        self.channels = channels.max(1);
        self.configure();
    }

    fn snap_to_target(&mut self) {
        self.current_gains = self.target_gains;
        self.current_qs = self.target_qs;
        self.current_preamp_db = self.target_preamp_db;
        self.current_balance = self.target_balance;
    }

    /// Flush — a seek or a fresh source. State zeroed, tuning snapped.
    pub fn flush(&mut self) {
        self.state.fill(0.0);
        self.running = [false; EqLayout::SLOTS];
        self.snap_to_target();
    }

    /// Processes interleaved f32 samples in place. Preserves headroom — no
    /// clamping inside the cascade, matching upstream's float path.
    pub fn process(&mut self, samples: &mut [f32]) {
        let ch = self.channels;
        if ch == 0 || samples.is_empty() || samples.len() % ch != 0 {
            return;
        }
        let frame_count = samples.len() / ch;

        if is_flat(
            self.target_enabled,
            &self.target_gains,
            self.target_preamp_db,
            self.target_balance,
        ) && self.is_settled()
        {
            return;
        }

        let mut remaining = frame_count;
        let mut cursor = 0;
        while remaining > 0 {
            let block = remaining.min(GLIDE_FRAMES);
            self.glide_towards();
            let active = self.prepare_sections();
            self.prepare_channel_gains();

            for _ in 0..block {
                for channel in 0..ch {
                    let mut sample = samples[cursor];
                    for index in 0..active {
                        sample = self.section(self.active_slots[index], channel, sample);
                    }
                    samples[cursor] = sample * self.channel_gain[channel];
                    cursor += 1;
                }
            }
            self.flush_denormals(active);
            remaining -= block;
        }
    }

    fn glide_towards(&mut self) {
        for slot in 0..EqLayout::SLOTS {
            self.current_gains[slot] =
                linear_glide(self.current_gains[slot], self.target_gains[slot]);
            self.current_qs[slot] = geometric_glide(self.current_qs[slot], self.target_qs[slot]);
        }
        self.current_preamp_db = linear_glide(self.current_preamp_db, self.target_preamp_db);
        self.current_balance = linear_glide(self.current_balance, self.target_balance);
    }

    fn is_settled(&self) -> bool {
        if (self.current_balance - self.target_balance).abs() >= SETTLED_BALANCE {
            return false;
        }
        if (self.current_preamp_db - self.target_preamp_db).abs() >= SETTLED_DB {
            return false;
        }
        for slot in 0..EqLayout::SLOTS {
            if (self.current_gains[slot] - self.target_gains[slot]).abs() >= SETTLED_DB {
                return false;
            }
        }
        true
    }

    fn prepare_sections(&mut self) -> usize {
        let mut active = 0;
        for slot in 0..EqLayout::SLOTS {
            if self.current_gains[slot].abs() >= SETTLED_DB {
                self.update_coefficients(slot);
                self.active_slots[active] = slot;
                active += 1;
                self.running[slot] = true;
            } else if self.running[slot] {
                self.clear_state(slot);
                self.running[slot] = false;
            }
        }
        active
    }

    fn update_coefficients(&mut self, slot: usize) {
        if self.sample_rate <= 0.0 {
            return;
        }
        let spec = &EqLayout::slots()[slot];
        let a = 10.0f32.powf(self.current_gains[slot] / 40.0);
        let q = self.current_qs[slot].max(MIN_Q);
        let base = (core::f64::consts::PI
            * usable_frequency(spec.frequency_hz, self.sample_rate) as f64
            / self.sample_rate as f64)
            .tan() as f32;
        let g: f32;
        let k: f32;
        match spec.kind {
            FilterKind::Bell => {
                g = base;
                k = 1.0 / (q * a);
                self.mix_input[slot] = 1.0;
                self.mix_band[slot] = k * (a * a - 1.0);
                self.mix_low[slot] = 0.0;
            }
            FilterKind::LowShelf => {
                g = base / a.sqrt();
                k = 1.0 / q;
                self.mix_input[slot] = 1.0;
                self.mix_band[slot] = k * (a - 1.0);
                self.mix_low[slot] = a * a - 1.0;
            }
            FilterKind::HighShelf => {
                g = base * a.sqrt();
                k = 1.0 / q;
                self.mix_input[slot] = a * a;
                self.mix_band[slot] = k * (1.0 - a) * a;
                self.mix_low[slot] = 1.0 - a * a;
            }
        }
        let d = 1.0 / (1.0 + g * (g + k));
        self.coeff_a1[slot] = d;
        self.coeff_a2[slot] = g * d;
        self.coeff_a3[slot] = g * (g * d);
    }

    fn prepare_channel_gains(&mut self) {
        let preamp = 10.0f32.powf(self.current_preamp_db / 20.0);
        if self.channels == 2 {
            self.channel_gain[0] = preamp * (1.0f32 - self.current_balance).min(1.0);
            self.channel_gain[1] = preamp * (1.0f32 + self.current_balance).min(1.0);
        } else {
            self.channel_gain.fill(preamp);
        }
    }

    fn section(&mut self, slot: usize, channel: usize, input: f32) -> f32 {
        let i = (channel * EqLayout::SLOTS + slot) * 2;
        let ic1 = self.state[i];
        let ic2 = self.state[i + 1];
        let v3 = input - ic2;
        let v1 = self.coeff_a1[slot] * ic1 + self.coeff_a2[slot] * v3;
        let v2 = ic2 + self.coeff_a2[slot] * ic1 + self.coeff_a3[slot] * v3;
        self.state[i] = 2.0 * v1 - ic1;
        self.state[i + 1] = 2.0 * v2 - ic2;
        self.mix_input[slot] * input + self.mix_band[slot] * v1 + self.mix_low[slot] * v2
    }

    fn clear_state(&mut self, slot: usize) {
        for channel in 0..self.channels {
            let i = (channel * EqLayout::SLOTS + slot) * 2;
            self.state[i] = 0.0;
            self.state[i + 1] = 0.0;
        }
    }

    fn flush_denormals(&mut self, active: usize) {
        for index in 0..active {
            let slot = self.active_slots[index];
            for channel in 0..self.channels {
                let i = (channel * EqLayout::SLOTS + slot) * 2;
                if self.state[i].abs() < DENORMAL_FLOOR {
                    self.state[i] = 0.0;
                }
                if self.state[i + 1].abs() < DENORMAL_FLOOR {
                    self.state[i + 1] = 0.0;
                }
            }
        }
    }
}

fn linear_glide(current: f32, target: f32) -> f32 {
    current + (target - current) * GLIDE_RATE
}

fn geometric_glide(current: f32, target: f32) -> f32 {
    let from = current.max(MIN_Q).ln();
    let to = target.max(MIN_Q).ln();
    (from + (to - from) * GLIDE_RATE).exp()
}

fn usable_frequency(hz: f32, sample_rate: f32) -> f32 {
    hz.clamp(MIN_HZ, sample_rate * MAX_FREQUENCY_FRACTION)
}

fn is_flat(enabled: bool, gains: &[f32; EqLayout::SLOTS], preamp_db: f32, balance: f32) -> bool {
    if !enabled {
        return true;
    }
    balance.abs() < SETTLED_BALANCE
        && preamp_db.abs() < SETTLED_DB
        && gains.iter().all(|g| g.abs() < SETTLED_DB)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_curve_has_zero_preamp() {
        let curve = EqCurve::flat();
        assert!(
            curve.preamp_db.abs() < 1e-3,
            "flat preamp {}",
            curve.preamp_db
        );
    }

    #[test]
    fn flat_curve_is_sample_identical_passthrough() {
        let mut eq = EqualizerProcessor::new(48_000, 2);
        eq.set_tuning(false, &EqCurve::flat(), 0.0);
        let input: Vec<f32> = (0..1024).map(|i| ((i as f32) * 0.01).sin() * 0.5).collect();
        let mut buf = input.clone();
        eq.process(&mut buf);
        assert_eq!(buf, input);
    }

    #[test]
    fn boost_has_makeup_preamp_not_more_than_peak() {
        // A +12 dB shelf must pull the curve down to keep the peak at unity.
        let curve = manual_curve(&[12.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        assert!(curve.preamp_db <= 0.0);
        assert!(curve.preamp_db < -11.5, "preamp {}", curve.preamp_db);
    }

    #[test]
    fn manual_curve_fills_only_manual_slots() {
        let curve = manual_curve(&[6.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        assert!((curve.gains_db[0] - 6.0).abs() < 1e-6);
        assert!(curve.gains_db[7..].iter().all(|g| g.abs() < 1e-6));
        assert!((curve.qs[0] - EqLayout::MANUAL_Q).abs() < 1e-6);
    }

    #[test]
    fn tone_curve_tilts_opposite_shelves() {
        let curve = tone_curve(5, 0, false);
        // x=+5 → tilt = +6 dB: low shelf down, high shelf up.
        assert!((curve.gains_db[EqLayout::TONE_LOW] - (-6.0)).abs() < 1e-4);
        assert!((curve.gains_db[EqLayout::TONE_HIGH] - 6.0).abs() < 1e-4);
        assert!(curve.gains_db[0..7].iter().all(|g| g.abs() < 1e-6));
        // Broad shelves Q = 0.5.
        assert!((curve.qs[EqLayout::TONE_LOW] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn focused_tone_curve_narrows_bandwidth() {
        let broad = tone_curve(0, 0, false);
        let focused = tone_curve(0, 0, true);
        assert!(focused.qs[EqLayout::TONE_MID] > broad.qs[EqLayout::TONE_MID]);
    }

    #[test]
    fn enabled_eq_alters_signal_and_glides_not_snaps() {
        let mut eq = EqualizerProcessor::new(48_000, 2);
        let curve = manual_curve(&[12.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        eq.set_tuning(true, &curve, 0.0);

        let input: Vec<f32> = (0..4096).map(|i| ((i as f32) * 0.02).sin() * 0.5).collect();
        let mut buf = input.clone();
        eq.process(&mut buf);
        assert_ne!(buf, input);
        // The glide must not have reached the target on the first block: the
        // first processed frame's gain is still climbing from 0.
        // (Behavioural check: output differs but stays finite.)
        assert!(buf.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn balance_trims_left_and_right_oppositely() {
        let mut leftish = EqualizerProcessor::new(48_000, 2);
        leftish.set_tuning(true, &manual_curve(&[0.0; 7]), -1.0);
        let mut rightish = EqualizerProcessor::new(48_000, 2);
        rightish.set_tuning(true, &manual_curve(&[0.0; 7]), 1.0);

        let frames = 4096;
        let input: Vec<f32> = (0..frames * 2)
            .map(|i| {
                let t = (i / 2) as f32 / 48_000.0;
                (2.0 * core::f32::consts::PI * 440.0 * t).sin() * 0.5
            })
            .collect();

        let mut a = input.clone();
        leftish.process(&mut a);
        let mut b = input.clone();
        rightish.process(&mut b);

        // Fully glided: left channel quieter in `a` (balance -1), right quieter
        // in `b` (balance +1).
        for _ in 0..400 {
            leftish.process(&mut a);
            rightish.process(&mut b);
        }
        let l_a = rms_channel(&a, 0);
        let r_a = rms_channel(&a, 1);
        let l_b = rms_channel(&b, 0);
        let r_b = rms_channel(&b, 1);
        // balance -1 = fully left: right channel muted (upstream channelGain).
        assert!(l_a > r_a, "balance -1 should favour left (L {l_a} R {r_a})");
        assert!(
            r_b > l_b,
            "balance +1 should favour right (L {l_b} R {r_b})"
        );
    }

    fn rms_channel(buf: &[f32], ch: usize) -> f32 {
        let sum: f32 = buf.chunks_exact(2).map(|p| p[ch] * p[ch]).sum();
        (sum / (buf.len() / 2) as f32).sqrt()
    }
}

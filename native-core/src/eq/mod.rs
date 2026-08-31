//! 10-band graphic equalizer — the Apple-side stand-in for Android's
//! `AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL`. Peaking biquads
//! at ISO centres, processed on the mixed stereo stream.

const BANDS: usize = 10;
const FREQS: [f32; BANDS] = [
    32.0, 64.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
];
const Q: f32 = 1.4;

struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1_l: f32,
    z2_l: f32,
    z1_r: f32,
    z2_r: f32,
}

impl Biquad {
    fn peaking(sample_rate: f32, freq: f32, gain_db: f32) -> Self {
        let a = 10.0f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * (freq / sample_rate).min(0.45);
        let alpha = w0.sin() / (2.0 * Q);
        let cos = w0.cos();
        let b0 = 1.0 + alpha * a;
        let b1 = -2.0 * cos;
        let b2 = 1.0 - alpha * a;
        let a0 = 1.0 + alpha / a;
        let a1 = -2.0 * cos;
        let a2 = 1.0 - alpha / a;
        Self {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
            z1_l: 0.0,
            z2_l: 0.0,
            z1_r: 0.0,
            z2_r: 0.0,
        }
    }

    fn process_stereo(&mut self, samples: &mut [f32]) {
        for pair in samples.chunks_exact_mut(2) {
            let l = pair[0];
            let r = pair[1];
            let out_l = self.b0 * l + self.z1_l;
            self.z1_l = self.b1 * l - self.a1 * out_l + self.z2_l;
            self.z2_l = self.b2 * l - self.a2 * out_l;
            let out_r = self.b0 * r + self.z1_r;
            self.z1_r = self.b1 * r - self.a1 * out_r + self.z2_r;
            self.z2_r = self.b2 * r - self.a2 * out_r;
            pair[0] = out_l;
            pair[1] = out_r;
        }
    }
}

pub struct GraphicEq {
    sample_rate: f32,
    gains_db: [f32; BANDS],
    bands: [Biquad; BANDS],
    enabled: bool,
}

impl GraphicEq {
    pub fn new(sample_rate: u32) -> Self {
        let sr = sample_rate.max(8_000) as f32;
        let gains = [0.0; BANDS];
        let bands = std::array::from_fn(|i| Biquad::peaking(sr, FREQS[i], 0.0));
        Self {
            sample_rate: sr,
            gains_db: gains,
            bands,
            enabled: false,
        }
    }

    pub fn set_gains_db(&mut self, gains: &[f32]) {
        let mut any = false;
        for i in 0..BANDS {
            let g = gains.get(i).copied().unwrap_or(0.0).clamp(-12.0, 12.0);
            self.gains_db[i] = g;
            if g.abs() > 0.01 {
                any = true;
            }
            self.bands[i] = Biquad::peaking(self.sample_rate, FREQS[i], g);
        }
        self.enabled = any;
    }

    pub fn retarget(&mut self, sample_rate: u32) {
        self.sample_rate = sample_rate.max(8_000) as f32;
        let gains = self.gains_db;
        self.set_gains_db(&gains);
    }

    pub fn process(&mut self, samples: &mut [f32]) {
        if !self.enabled {
            return;
        }
        for band in &mut self.bands {
            band.process_stereo(samples);
        }
    }
}

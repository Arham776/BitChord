//! Port of upstream `VocalSpectrogram` + `VocalTracker.kt`.

use super::models;
use super::resample;
use super::{fft, hann_window, Complex};

pub const SAMPLE_RATE: f64 = 44_100.0;
pub const CHANNELS: usize = 2;
pub const FFT: usize = 4096;
pub const BINS: usize = FFT / 2 + 1;
pub const HOP: usize = 1024;
pub const FIXED_FRAMES: usize = 960;
/// Longest source window the fixed-length STFT can ingest without exceeding
/// [`FIXED_FRAMES`]. Upstream trims the decode to
/// `(FIXED_FRAMES - 2) · hop / rate` (TrackAnalyzer), which lands at 958
/// frames; the previous 22.8 s window decoded to 982 frames and made
/// [`track`] reject every normal track, so no vocal mask was ever produced.
pub const MAX_WINDOW_SECONDS: f64 =
    (FIXED_FRAMES as f64 - 2.0) * HOP as f64 / SAMPLE_RATE;
const LOW_HZ: f64 = 200.0;
const HIGH_HZ: f64 = 4000.0;

use rten_tensor::NdTensor;

/// One vocal-presence value per STFT frame in [0, 1].
pub fn track(left: &[f32], right: &[f32], rate: f64) -> Option<Vec<f32>> {
    if left.is_empty() || left.len() != right.len() {
        return None;
    }
    let left = if (rate - SAMPLE_RATE).abs() > 1.0 {
        resample(left, rate, SAMPLE_RATE)
    } else {
        left.to_vec()
    };
    let right = if (rate - SAMPLE_RATE).abs() > 1.0 {
        resample(right, rate, SAMPLE_RATE)
    } else {
        right.to_vec()
    };
    let spec = compute(&left, &right, SAMPLE_RATE)?;
    if spec.frames > FIXED_FRAMES {
        log::debug!(
            "automix: vocal window of {} frames exceeds {}",
            spec.frames,
            FIXED_FRAMES
        );
        return None;
    }
    models::with_vocal(|model| infer(model, &spec)).flatten()
}

struct Spectrogram {
    values: Vec<f32>,
    frames: usize,
}

fn compute(left: &[f32], right: &[f32], sample_rate: f64) -> Option<Spectrogram> {
    if (sample_rate - SAMPLE_RATE).abs() > 1.0 {
        return None;
    }
    let pad = FFT / 2;
    if left.len() <= pad + 1 {
        return None;
    }
    let window = hann_window(FFT);
    let mut padded = [Vec::new(), Vec::new()];
    for (channel, source) in [left, right].into_iter().enumerate() {
        let out = &mut padded[channel];
        out.reserve(source.len() + 2 * pad);
        for index in (1..=pad).rev() {
            out.push(source[index]);
        }
        out.extend_from_slice(source);
        for index in 1..=pad {
            out.push(source[source.len() - 1 - index]);
        }
    }
    let padded_len = padded[0].len();
    if padded_len < FFT {
        return None;
    }
    let frames = (padded_len - FFT) / HOP + 1;
    let mut values = vec![0.0f32; CHANNELS * BINS * frames];
    let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; FFT];
    for channel in 0..CHANNELS {
        let source = &padded[channel];
        let channel_base = channel * BINS * frames;
        for frame in 0..frames {
            let start = frame * HOP;
            for (index, bin) in spectrum.iter_mut().enumerate() {
                *bin = Complex {
                    re: source[start + index] as f64 * window[index],
                    im: 0.0,
                };
            }
            fft(&mut spectrum);
            for bin in 0..BINS {
                values[channel_base + bin * frames + frame] = spectrum[bin].abs() as f32;
            }
        }
    }
    Some(Spectrogram { values, frames })
}

fn infer(model: &rten::Model, spec: &Spectrogram) -> Option<Vec<f32>> {
    let input_id = *model.input_ids().first()?;
    let mix = fill_fixed_frames(&spec.values, spec.frames);
    let tensor = NdTensor::from_data([1, CHANNELS, BINS, FIXED_FRAMES], mix.clone());
    let outputs = model
        .run(vec![(input_id, tensor.into())], model.output_ids(), None)
        .ok()?;
    let target = super::models::flatten_f32(outputs.first()?)?;
    if target.len() < CHANNELS * BINS * FIXED_FRAMES {
        return None;
    }
    Some(reduce_to_band_curve(&mix, &target, spec.frames))
}

fn fill_fixed_frames(values: &[f32], frames: usize) -> Vec<f32> {
    let mut into = vec![0.0f32; CHANNELS * BINS * FIXED_FRAMES];
    if frames == FIXED_FRAMES {
        into.copy_from_slice(values);
        return into;
    }
    for channel in 0..CHANNELS {
        for bin in 0..BINS {
            let src = (channel * BINS + bin) * frames;
            let dst = (channel * BINS + bin) * FIXED_FRAMES;
            let n = frames.min(FIXED_FRAMES);
            into[dst..dst + n].copy_from_slice(&values[src..src + n]);
        }
    }
    into
}

fn reduce_to_band_curve(mix: &[f32], target: &[f32], usable_frames: usize) -> Vec<f32> {
    let low_bin = ((LOW_HZ * FFT as f64 / SAMPLE_RATE).floor() as usize).max(0);
    let high_bin = ((HIGH_HZ * FFT as f64 / SAMPLE_RATE).ceil() as usize).min(BINS - 1);
    if high_bin <= low_bin || usable_frames == 0 {
        return Vec::new();
    }
    let mut curve = vec![0.0f32; usable_frames];
    for frame in 0..usable_frames {
        let mut sum = 0.0f64;
        let mut count = 0;
        for channel in 0..CHANNELS {
            for bin in low_bin..=high_bin {
                let index = (channel * BINS + bin) * FIXED_FRAMES + frame;
                let mix_value = mix[index];
                if mix_value <= 1e-6 {
                    continue;
                }
                let ratio = (target[index] / mix_value).clamp(0.0, 1.0);
                sum += ratio as f64;
                count += 1;
            }
        }
        curve[frame] = if count > 0 { (sum / count as f64) as f32 } else { 0.0 };
    }
    curve
}


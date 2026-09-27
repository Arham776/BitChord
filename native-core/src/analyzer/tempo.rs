//! Offline tempo and beat-grid estimation — faithful Rust port of upstream
//! `native/analyzer/tempo_analysis.cpp` (`AnalyzeTempo`).
//!
//! Spectral-flux onset envelope + autocorrelation tempo search + a
//! phase-locked tracking loop. This is the confidence a transition policy
//! without a trained beat-tracking model has to work with: deliberately less
//! trusted than a model's grid (see `MIN_BEATMATCH_CONFIDENCE`), but real
//! evidence — not a guess — because it carries actual beat and downbeat times.
//!
//! Ported from Orchard (https://github.com/SFG5453/Orchard) via BitChord's
//! `native/analyzer` — Copyright (C) 2026 SFG545, Copyright (C) 2026 Kushagra
//! Singh. AGPLv3-or-later, kept as part of the same GPL-3 combined work.

use super::{fft, Complex, PI};

const FRAME_SIZE: usize = 512;
const HOP_SIZE: usize = 128;
/// Bins up to this frequency carry the bass-band flux used for downbeats.
const LOW_BAND_HZ: f64 = 150.0;
const MAX_ENVELOPE_SECONDS: f64 = 1200.0;
const MAX_TEMPO_SEARCH_SECONDS: f64 = 180.0;
const PHASE_SEARCH_SECONDS: f64 = 30.0;
const PHASE_GAIN: f64 = 0.20;
const INTERVAL_GAIN: f64 = 0.01;

struct OnsetEnvelopes {
    full: Vec<f64>,
    low: Vec<f64>,
}

pub(crate) struct TempoResult {
    pub(crate) bpm: f64,
    pub(crate) beat_interval: f64,
    pub(crate) first_beat: f64,
    pub(crate) confidence: f64,
    pub(crate) beats: Vec<f64>,
    pub(crate) downbeats: Vec<f64>,
}

fn clamp(value: f64, minimum: f64, maximum: f64) -> f64 {
    value.max(minimum).min(maximum)
}

/// Normalizes an onset envelope in place: subtract a local mean to suppress
/// steady-state energy, then peak-normalize and sqrt-expand what remains.
fn normalize_envelope(envelope: &mut [f64], frames_per_second: f64) {
    if envelope.is_empty() {
        return;
    }
    let radius = (frames_per_second * 0.35).max(2.0) as usize;
    let mut prefix = vec![0.0f64; envelope.len() + 1];
    for (index, value) in envelope.iter().enumerate() {
        prefix[index + 1] = prefix[index] + value;
    }
    for index in 0..envelope.len() {
        let left = index.saturating_sub(radius);
        let right = (index + radius + 1).min(envelope.len());
        let local_mean = (prefix[right] - prefix[left]) / (right - left).max(1) as f64;
        envelope[index] = (envelope[index] - local_mean * 1.08).max(0.0);
    }
    let peak = envelope.iter().copied().fold(0.0f64, f64::max);
    if peak > 0.0 {
        for value in envelope {
            *value = (*value / peak).sqrt();
        }
    }
}

/// Full-band and bass-band spectral-flux onset envelopes.
fn onset_envelope(
    samples: &[f32],
    sample_rate: f64,
    frame_size: usize,
    hop_size: usize,
) -> OnsetEnvelopes {
    let mut result = OnsetEnvelopes {
        full: Vec::new(),
        low: Vec::new(),
    };
    let maximum_samples = samples
        .len()
        .min((sample_rate * MAX_ENVELOPE_SECONDS) as usize);
    if maximum_samples < frame_size {
        return result;
    }

    let frame_count = 1 + (maximum_samples - frame_size) / hop_size;
    // Bins from DC up to LOW_BAND_HZ. At 11 025 Hz with a 512-sample frame each
    // bin spans 21.5 Hz, so this is bins 1 through 7.
    let low_band_bins = (frame_size / 2)
        .min((LOW_BAND_HZ * frame_size as f64 / sample_rate) as usize)
        .max(2);
    result.full = vec![0.0; frame_count];
    result.low = vec![0.0; frame_count];
    let mut previous = vec![0.0f64; frame_size / 2];
    let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; frame_size];
    // Symmetric Hann, denominator frame_size - 1 (unlike the periodic Hann the
    // mel path uses) — matches the C++ onset window exactly.
    let mut window = vec![0.0f64; frame_size];
    for (index, value) in window.iter_mut().enumerate() {
        *value = 0.5 - 0.5 * (2.0 * PI * index as f64 / (frame_size - 1) as f64).cos();
    }

    for frame in 0..frame_count {
        let start = frame * hop_size;
        for index in 0..frame_size {
            spectrum[index] = Complex {
                re: samples[start + index] as f64 * window[index],
                im: 0.0,
            };
        }
        fft(&mut spectrum);

        let mut flux = 0.0;
        let mut low_flux = 0.0;
        for bin in 1..frame_size / 2 {
            let magnitude = spectrum[bin].abs().ln_1p();
            let rise = (magnitude - previous[bin]).max(0.0);
            flux += rise;
            if bin < low_band_bins {
                low_flux += rise;
            }
            previous[bin] = magnitude;
        }
        result.full[frame] = flux;
        result.low[frame] = low_flux;
    }

    let frames_per_second = sample_rate / hop_size as f64;
    normalize_envelope(&mut result.full, frames_per_second);
    normalize_envelope(&mut result.low, frames_per_second);
    result
}

/// Energy-normalized autocorrelation.
fn correlation(values: &[f64], lag: usize, limit: usize) -> f64 {
    let length = limit.min(values.len());
    if lag == 0 || lag >= length {
        return 0.0;
    }
    let mut cross = 0.0;
    let mut left_energy = 0.0;
    let mut right_energy = 0.0;
    for index in lag..length {
        let left = values[index];
        let right = values[index - lag];
        cross += left * right;
        left_energy += left * left;
        right_energy += right * right;
    }
    cross / (left_energy * right_energy).max(1e-12).sqrt()
}

/// Linear interpolation so sub-frame lag refinement can participate in phase
/// scoring without resampling the whole envelope.
fn sample_envelope(values: &[f64], position: f64) -> f64 {
    if position < 0.0 || position >= values.len() as f64 - 1.0 {
        return 0.0;
    }
    let left = position.floor() as usize;
    let fraction = position - left as f64;
    values[left] * (1.0 - fraction) + values[left + 1] * fraction
}

/// Log-Gaussian preference for tempi near 120 BPM.
fn metrical_prior(bpm: f64) -> f64 {
    if !(bpm > 0.0) {
        return 0.0;
    }
    let octaves = (bpm / 120.0).log2() / 0.7;
    (-0.5 * octaves * octaves).exp()
}

pub(crate) fn analyze_tempo(
    samples: &[f32],
    sample_rate: f64,
    duration: f64,
    audible_start: f64,
) -> Option<TempoResult> {
    let envelopes = onset_envelope(samples, sample_rate, FRAME_SIZE, HOP_SIZE);
    let envelope = &envelopes.full;
    // Short or silent-enough inputs fail closed to no tempo.
    if envelope.len() < 64 {
        return None;
    }

    let frames_per_second = sample_rate / HOP_SIZE as f64;
    let search_limit = envelope
        .len()
        .min((frames_per_second * MAX_TEMPO_SEARCH_SECONDS) as usize);
    let minimum_lag = 2usize.max((frames_per_second * 60.0 / 200.0).floor() as usize);
    let maximum_lag = (frames_per_second * 60.0 / 70.0).ceil() as usize;
    let mut scores = vec![0.0f64; maximum_lag + 1];
    let mut best_lag = minimum_lag;
    for lag in minimum_lag..=maximum_lag {
        let bpm = frames_per_second * 60.0 / lag as f64;
        let tempo_prior = (-((bpm - 118.0) / 75.0).powi(2)).exp();
        scores[lag] = correlation(envelope, lag, search_limit)
            + 0.42 * correlation(envelope, lag * 2, search_limit)
            + 0.08 * tempo_prior;
        if scores[lag] > scores[best_lag] {
            best_lag = lag;
        }
    }

    // Resolve the metrical level against the winner's half and double lag.
    {
        let mut best_metrical = -1.0f64;
        let mut metrical_lag = best_lag;
        for ratio in [0.5, 1.0, 2.0] {
            let candidate = (best_lag as f64 * ratio).round() as usize;
            if candidate < minimum_lag || candidate > maximum_lag {
                continue;
            }
            let bpm = frames_per_second * 60.0 / candidate as f64;
            let score = correlation(envelope, candidate, search_limit) * metrical_prior(bpm);
            if score > best_metrical {
                best_metrical = score;
                metrical_lag = candidate;
            }
        }
        best_lag = metrical_lag;
    }

    let mut refined_lag = best_lag as f64;
    if best_lag > minimum_lag && best_lag < maximum_lag {
        let left = correlation(envelope, best_lag - 1, search_limit);
        let center = correlation(envelope, best_lag, search_limit);
        let right = correlation(envelope, best_lag + 1, search_limit);
        let denominator = left - 2.0 * center + right;
        if denominator.abs() > 1e-9 {
            refined_lag += clamp(0.5 * (left - right) / denominator, -0.5, 0.5);
        }
    }

    // Phase: which offset within the beat carries the onsets.
    let estimate_phase = |lag: f64, limit: usize| -> (i32, f64) {
        let phase_count = 1usize.max(lag.round() as usize);
        let end = (limit.min(envelope.len())) as f64;
        let mut best_score = -1.0f64;
        let mut best = 0;
        for phase in 0..phase_count {
            let mut score = 0.0;
            let mut count = 0;
            let mut position = phase as f64;
            while position < end {
                score += sample_envelope(envelope, position);
                count += 1;
                position += lag;
            }
            score /= count.max(1) as f64;
            if score > best_score {
                best_score = score;
                best = phase;
            }
        }
        (best as i32, best_score)
    };

    let (mut best_phase, mut best_phase_score) = estimate_phase(
        refined_lag,
        (frames_per_second * PHASE_SEARCH_SECONDS) as usize,
    );

    let anchor_first_beat = |phase: i32, lag: f64| -> f64 {
        let interval_seconds = lag / frames_per_second;
        let mut first = phase as f64 / frames_per_second;
        while first + interval_seconds < audible_start - 0.15 {
            first += interval_seconds;
        }
        while first > audible_start + interval_seconds {
            first -= interval_seconds;
        }
        first.max(0.0)
    };
    let mut first_beat = anchor_first_beat(best_phase, refined_lag);

    let envelope_end = envelope.len() as f64 - 1.0;
    let last_frame = duration * frames_per_second;

    let track = |start_lag: f64, first: f64| -> (Vec<f64>, Vec<f64>) {
        let mut beats = Vec::new();
        let mut intervals = Vec::new();
        let search_radius = start_lag * 0.25;
        let max_interval_drift = start_lag * 0.03;

        let mut position = first * frames_per_second;
        let mut interval = start_lag;

        while position <= last_frame + 1e-6 {
            beats.push(position.max(0.0));
            let predicted = position + interval;
            if predicted > last_frame + 1e-6 {
                break;
            }

            if predicted + search_radius < envelope_end {
                let mut best_value = -1.0f64;
                let mut best_offset = 0.0f64;
                let low = (predicted - search_radius).floor() as isize;
                let high = (predicted + search_radius).ceil() as isize;
                let mut frame = low.max(0);
                while frame <= high && frame < envelope.len() as isize {
                    let value = envelope[frame as usize];
                    if value > best_value {
                        best_value = value;
                        best_offset = frame as f64;
                    }
                    frame += 1;
                }
                // Only a real onset may steer the loop.
                if best_value > 0.15 {
                    let index = best_offset as usize;
                    if index > 0 && index + 1 < envelope.len() {
                        let left = envelope[index - 1];
                        let center = envelope[index];
                        let right = envelope[index + 1];
                        let denominator = left - 2.0 * center + right;
                        if denominator.abs() > 1e-9 {
                            best_offset += clamp(0.5 * (left - right) / denominator, -0.5, 0.5);
                        }
                    }
                    let error = best_offset - predicted;
                    position = predicted + PHASE_GAIN * error;
                    interval = clamp(
                        interval + INTERVAL_GAIN * error,
                        start_lag - max_interval_drift,
                        start_lag + max_interval_drift,
                    );
                    intervals.push(interval);
                    continue;
                }
            }
            position = predicted;
        }
        (beats, intervals)
    };

    // First pass learns the interval; second lays the grid already locked.
    let learning = track(refined_lag, first_beat);
    let mut grid = learning.clone();
    if learning.1.len() >= 8 {
        let mut sorted = learning.1.clone();
        sorted.sort_by(|a, b| a.total_cmp(b));
        let locked = sorted[sorted.len() / 2];
        if locked > 0.0 {
            refined_lag = locked;
        }
        let relocked = estimate_phase(refined_lag, envelope.len());
        best_phase = relocked.0;
        best_phase_score = relocked.1;
        first_beat = anchor_first_beat(best_phase, refined_lag);
        grid = track(refined_lag, first_beat);
    }

    let mut result = TempoResult {
        bpm: frames_per_second * 60.0 / refined_lag,
        beat_interval: 0.0,
        first_beat,
        confidence: 0.0,
        beats: Vec::with_capacity(grid.0.len()),
        downbeats: Vec::new(),
    };
    result.beat_interval = 60.0 / result.bpm;
    for frame in &grid.0 {
        result.beats.push(frame / frames_per_second);
    }

    // Which of the four beats is beat one — bass-band onset strength.
    let mut downbeat_offset = 0usize;
    let mut downbeat_score = -1.0f64;
    for offset in 0..4usize {
        let mut low_score = 0.0;
        let mut full_score = 0.0;
        let mut count = 0;
        let mut beat = offset;
        while beat < result.beats.len() && beat < 256 {
            let position_frames = result.beats[beat] * frames_per_second;
            low_score += sample_envelope(&envelopes.low, position_frames);
            full_score += sample_envelope(envelope, position_frames);
            count += 1;
            beat += 4;
        }
        let score = (low_score + 0.4 * full_score) / count.max(1) as f64;
        if score > downbeat_score {
            downbeat_score = score;
            downbeat_offset = offset;
        }
    }
    let mut beat = downbeat_offset;
    while beat < result.beats.len() {
        result.downbeats.push(result.beats[beat]);
        beat += 4;
    }

    // Onset flux belongs to the whole window; report its centre, not its start.
    let frame_centre_seconds = FRAME_SIZE as f64 / (2.0 * sample_rate);
    result.first_beat += frame_centre_seconds;
    for beat in &mut result.beats {
        *beat += frame_centre_seconds;
    }
    for beat in &mut result.downbeats {
        *beat += frame_centre_seconds;
    }

    let mut runner_up = 0.0f64;
    for lag in minimum_lag..=maximum_lag {
        if (lag as f64 - best_lag as f64).abs() > 2.0 {
            runner_up = runner_up.max(scores[lag]);
        }
    }
    let separation = (scores[best_lag] - runner_up) / scores[best_lag].max(0.05);
    result.confidence = clamp(
        0.35 * scores[best_lag] + 0.35 * best_phase_score + 0.3 * separation.max(0.0),
        0.0,
        1.0,
    );
    if !result.bpm.is_finite() || result.bpm < 60.0 || result.bpm > 220.0 {
        return None;
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracks_a_120_bpm_click_track() {
        let rate = 11_025.0;
        let duration = 30.0;
        let samples_len = (duration * rate) as usize;
        let mut samples = vec![0.0f32; samples_len];
        let beat_interval = 0.5; // 120 BPM
        let mut t = 0.0;
        while t < duration - 0.1 {
            let start = (t * rate) as usize;
            // A short decaying click so each onset is a distinct flux peak.
            for i in 0..24 {
                let index = start + i;
                if index < samples_len {
                    samples[index] = (0.9 * (-(i as f64) / 6.0).exp()) as f32;
                }
            }
            t += beat_interval;
        }
        let result =
            analyze_tempo(&samples, rate, duration, 0.0).expect("click track should yield a tempo");
        assert!(
            (100.0..=140.0).contains(&result.bpm),
            "bpm {} outside 100..140",
            result.bpm
        );
        assert!(!result.beats.is_empty());
        assert!(!result.downbeats.is_empty());
        assert!(result.confidence > 0.0);
    }
}

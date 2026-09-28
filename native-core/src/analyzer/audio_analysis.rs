//! Offline whole-track analysis — faithful Rust port of upstream
//! `native/analyzer/audio_analysis.cpp` (`AnalyzeAudio`): envelope, tempo,
//! key/chroma, spectral bands, and structure. All DSP, no ML model.
//!
//! Answers "where does the music actually end, where can a transition enter
//! and leave, how loud is it there, and is anyone singing". The transition
//! policy needs a beat grid (from [`super::tempo`]) to know *how* to mix, and
//! these features to know *where*.
//!
//! Ported from Orchard (https://github.com/SFG5453/Orchard) via BitChord's
//! `native/analyzer` — Copyright (C) 2026 SFG545, Copyright (C) 2026 Kushagra
//! Singh. AGPLv3-or-later, kept as part of the same GPL-3 combined work.

use super::tempo::{self, TempoResult};
use super::{fft, Complex, PI};

/// The rate the analyzer's window and hop constants assume. Callers resample
/// whole-track mono to this before analysis.
pub(crate) const ANALYSIS_RATE: f64 = 11_025.0;

#[derive(Clone, Debug, Default)]
pub(crate) struct EnergyPoint {
    pub(crate) time: f64,
    pub(crate) energy: f64,
}

#[derive(Clone, Debug)]
pub(crate) struct MixCuePoint {
    pub(crate) time: f64,
    pub(crate) score: f64,
    /// Cue type label (`pickup` / `intro_drop` / `main_drop` / `energy_cliff` /
    /// `outro_start` / `content_end`). Read by the planner's mix-out anchor
    /// ranking once that branch is wired.
    #[allow(dead_code)]
    pub(crate) kind: String,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct AudioAnalysis {
    pub(crate) duration: f64,
    pub(crate) bpm: f64,
    pub(crate) beat_interval: f64,
    pub(crate) first_beat: f64,
    pub(crate) beat_confidence: f64,
    pub(crate) beats: Vec<f64>,
    pub(crate) downbeats: Vec<f64>,
    pub(crate) key: String,
    pub(crate) key_confidence: f64,
    pub(crate) audible_start_time: f64,
    pub(crate) pickup_confidence: f64,
    pub(crate) content_end_time: f64,
    pub(crate) mix_out_time: f64,
    pub(crate) intro_end_time: f64,
    pub(crate) outro_start_time: f64,
    pub(crate) mix_in_time: f64,
    pub(crate) mix_in_confidence: f64,
    pub(crate) vocal_probability: f64,
    pub(crate) loudness_lufs: f64,
    pub(crate) peak_dbfs: f64,
    pub(crate) dynamic_range_db: f64,
    pub(crate) energy_curve: Vec<EnergyPoint>,
    pub(crate) low_energy_curve: Vec<EnergyPoint>,
    pub(crate) vocal_activity_mask: Vec<f64>,
    /// Percussive / high-band activity parallel to `energy_curve` (0…1).
    pub(crate) drum_activity_mask: Vec<f64>,
    /// Low-band / bass activity parallel to `energy_curve` (0…1).
    pub(crate) bass_activity_mask: Vec<f64>,
    /// Perceived pace (energy × novelty), parallel to `energy_curve` (0…1).
    pub(crate) pace_curve: Vec<EnergyPoint>,
    pub(crate) mix_in_candidates: Vec<MixCuePoint>,
    pub(crate) mix_out_candidates: Vec<MixCuePoint>,
    pub(crate) phrase_boundaries: Vec<f64>,
    /// Coarser section starts (novelty peaks on the downbeat grid).
    pub(crate) section_boundaries: Vec<f64>,
    /// Mid-level segment starts between phrase and section.
    pub(crate) segment_boundaries: Vec<f64>,
}

fn clamp(value: f64, minimum: f64, maximum: f64) -> f64 {
    value.max(minimum).min(maximum)
}

fn to_db(value: f64) -> f64 {
    if value > 1e-9 {
        20.0 * value.log10()
    } else {
        -70.0
    }
}

fn percentile(values: &[f64], ratio: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut copy = values.to_vec();
    let index = (clamp(ratio, 0.0, 1.0) * (copy.len() - 1) as f64) as usize;
    copy.select_nth_unstable_by(index, |a, b| a.total_cmp(b));
    copy[index]
}

fn average(values: &[f64], start: usize, end: usize) -> f64 {
    let start = start.min(values.len());
    let end = end.min(values.len()).max(start);
    if start == end {
        return 0.0;
    }
    values[start..end].iter().sum::<f64>() / (end - start) as f64
}

struct EnvelopeResult {
    window_seconds: f64,
    noise_floor: f64,
    reference: f64,
    threshold: f64,
    audible_start: f64,
    pickup_confidence: f64,
    content_end: f64,
    levels: Vec<f64>,
}

impl Default for EnvelopeResult {
    fn default() -> Self {
        Self {
            window_seconds: 0.25,
            noise_floor: 0.0,
            reference: 0.0,
            threshold: 0.0,
            audible_start: 0.0,
            pickup_confidence: 0.0,
            content_end: 0.0,
            levels: Vec::new(),
        }
    }
}

fn has_material_recovery(
    levels: &[f64],
    start: usize,
    sustain_windows: usize,
    reference: f64,
    quiet_level: f64,
) -> bool {
    if reference <= 0.0 || quiet_level >= reference * 0.38 {
        return false;
    }
    let threshold = (reference * 0.72).max(quiet_level * 1.8);
    for index in start..levels.len() {
        if index + sustain_windows > levels.len() {
            break;
        }
        if average(levels, index, index + sustain_windows) >= threshold {
            return true;
        }
    }
    false
}

fn has_quiet_then_recovery(
    levels: &[f64],
    start: usize,
    sustain_windows: usize,
    reference: f64,
) -> bool {
    if reference <= 0.0 {
        return false;
    }
    let mut found_quiet = false;
    for index in start..levels.len() {
        if index + sustain_windows > levels.len() {
            break;
        }
        let window_average = average(levels, index, index + sustain_windows);
        if window_average < reference * 0.38 {
            found_quiet = true;
        } else if found_quiet && window_average >= reference * 0.72 {
            return true;
        }
    }
    false
}

/// 250 ms RMS windows; percentile-derived reference/noise levels; sustained
/// activity locates the pickup, a quiet-tail pass separates content end from
/// file duration.
fn analyze_envelope(samples: &[f32], sample_rate: f64, duration: f64) -> EnvelopeResult {
    let mut result = EnvelopeResult::default();
    let window_size = (sample_rate * result.window_seconds).max(1.0) as usize;
    let mut start = 0usize;
    while start < samples.len() {
        let end = (start + window_size).min(samples.len());
        let sum: f64 = samples[start..end]
            .iter()
            .map(|s| (*s as f64) * (*s as f64))
            .sum();
        result.levels.push((sum / (end - start).max(1) as f64).sqrt());
        start += window_size;
    }
    if result.levels.is_empty() {
        return result;
    }

    result.noise_floor = percentile(&result.levels, 0.05);
    result.reference = percentile(&result.levels, 0.85);
    result.threshold = (0.0025f64)
        .max((result.noise_floor * 2.6).min(result.reference * 0.28))
        .max(result.reference * 0.1);
    let sustain = (1.5 / result.window_seconds).round().max(4.0) as usize;
    for index in 0..result.levels.len() {
        if index + sustain > result.levels.len() {
            break;
        }
        let mut active = 0usize;
        let mut peak = 0.0f64;
        for cursor in index..index + sustain {
            if result.levels[cursor] >= result.threshold {
                active += 1;
            }
            peak = peak.max(result.levels[cursor]);
        }
        if active < sustain * 2 / 3 || peak < result.threshold * 1.45 {
            continue;
        }
        result.audible_start = (index as f64 * result.window_seconds - 0.1).max(0.0);
        let local = average(&result.levels, index, index + sustain);
        result.pickup_confidence = clamp(
            (local - result.noise_floor) / (result.reference - result.noise_floor).max(1e-6),
            0.0,
            1.0,
        );
        break;
    }

    result.content_end = duration;
    let silence_threshold = (0.0015f64)
        .max((result.threshold * 0.25).min(result.reference * 0.04));
    let mut quiet_start = result.levels.len();
    while quiet_start > 0 && result.levels[quiet_start - 1] < silence_threshold {
        quiet_start -= 1;
    }
    let trailing_silence = duration - quiet_start as f64 * result.window_seconds;
    if trailing_silence >= 0.35 {
        result.content_end = (quiet_start as f64 * result.window_seconds).max(0.0);
    } else {
        for end in (sustain..=result.levels.len()).rev() {
            let start = end - sustain;
            let mut active = 0usize;
            for cursor in start..end {
                if result.levels[cursor] >= result.threshold {
                    active += 1;
                }
            }
            if active >= sustain / 2
                && average(&result.levels, start, end) >= result.threshold * 0.85
            {
                result.content_end = (end as f64 * result.window_seconds).min(duration);
                break;
            }
        }
    }
    result
}

/// Finds a late internal silence bordered by resumed audio, then backtracks to
/// its energy cliff. Terminal silence remains the envelope's content-end cue.
fn find_mix_out_time(
    samples: &[f32],
    sample_rate: f64,
    duration: f64,
    envelope: &EnvelopeResult,
) -> f64 {
    const WINDOW_SECONDS: f64 = 0.05;
    let window_size = (sample_rate * WINDOW_SECONDS).max(1.0) as usize;
    let mut levels = Vec::new();
    let mut start = 0usize;
    while start < samples.len() {
        let end = (start + window_size).min(samples.len());
        let sum: f64 = samples[start..end]
            .iter()
            .map(|s| (*s as f64) * (*s as f64))
            .sum();
        levels.push((sum / (end - start).max(1) as f64).sqrt());
        start += window_size;
    }
    if levels.is_empty() {
        return envelope.content_end;
    }

    let silence_threshold = (0.0015f64)
        .max((envelope.threshold * 0.25).min(envelope.reference * 0.04));
    let search_start = levels.len().min((duration * 0.55 / WINDOW_SECONDS) as usize);
    let context_windows = (2.0 / WINDOW_SECONDS) as usize;
    let recovery_windows = (3.0 / WINDOW_SECONDS).round().max(1.0) as usize;
    let mut best_index = 0usize;
    let mut best_duration = 0.0f64;

    let mut index = search_start;
    while index < levels.len() {
        if levels[index] >= silence_threshold {
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while end < levels.len() && levels[end] < silence_threshold {
            end += 1;
        }
        let silence_duration = (end - index) as f64 * WINDOW_SECONDS;
        let silence_end = end as f64 * WINDOW_SECONDS;
        if silence_duration >= 0.3 && silence_end <= duration - 4.0 {
            let before_start = if index > context_windows {
                index - context_windows
            } else {
                0
            };
            let after_end = (end + context_windows).min(levels.len());
            let before_peak = levels[before_start..index]
                .iter()
                .copied()
                .fold(0.0f64, f64::max);
            let after_peak = levels[end..after_end]
                .iter()
                .copied()
                .fold(0.0f64, f64::max);
            let quiet_level = average(&levels, index, end);
            let early_gap = index as f64 * WINDOW_SECONDS < envelope.content_end * 0.8;
            if before_peak >= silence_threshold * 2.0
                && after_peak >= silence_threshold * 2.0
                && (!early_gap
                    || !has_material_recovery(
                        &levels,
                        end,
                        recovery_windows,
                        envelope.reference,
                        quiet_level,
                    ))
                && silence_duration > best_duration
            {
                best_index = index;
                best_duration = silence_duration;
            }
        }
        index = end;
    }
    if best_index == 0 {
        return envelope.content_end;
    }

    let cliff_threshold = (silence_threshold * 2.0).max(envelope.reference * 0.65);
    let maximum_backtrack = (4.0 / WINDOW_SECONDS) as usize;
    let mut cliff_start = best_index;
    while cliff_start > search_start
        && best_index - cliff_start < maximum_backtrack
        && levels[cliff_start - 1] < cliff_threshold
    {
        cliff_start -= 1;
    }
    cliff_start as f64 * WINDOW_SECONDS
}

fn nearest_downbeat(downbeats: &[f64], target: f64, fallback: f64) -> f64 {
    if downbeats.is_empty() {
        return fallback;
    }
    match downbeats.binary_search_by(|d| d.total_cmp(&target)) {
        Ok(index) => downbeats[index],
        Err(0) => downbeats[0],
        Err(index) if index == downbeats.len() => *downbeats.last().unwrap(),
        Err(index) => {
            if target - downbeats[index - 1] <= downbeats[index] - target {
                downbeats[index - 1]
            } else {
                downbeats[index]
            }
        }
    }
}

fn downbeat_at_or_before(downbeats: &[f64], target: f64, fallback: f64) -> f64 {
    if downbeats.is_empty() {
        return fallback;
    }
    match downbeats.binary_search_by(|d| d.total_cmp(&target)) {
        Ok(index) => downbeats[index],
        Err(0) => downbeats[0],
        Err(index) => downbeats[index - 1],
    }
}

fn vocal_probability_from(low: f64, vocal: f64, high: f64, flatness: f64) -> f64 {
    let total = low + vocal + high;
    let mid_ratio = vocal / total.max(1e-12);
    let low_ratio = low / total.max(1e-12);
    let score = -2.4 + 5.2 * mid_ratio - 0.8 * low_ratio + 0.6 * flatness;
    clamp(1.0 / (1.0 + (-score).exp()), 0.0, 1.0)
}

fn analyze_key_and_timbre(
    samples: &[f32],
    sample_rate: f64,
    start_time: f64,
    end_time: f64,
    result: &mut AudioAnalysis,
    low_frames: &mut Vec<EnergyPoint>,
    vocal_frames: &mut Vec<EnergyPoint>,
    high_frames: &mut Vec<EnergyPoint>,
) {
    const FRAME_SIZE: usize = 4096;
    let hop_size = (sample_rate * 0.65).max(FRAME_SIZE as f64) as usize;
    let first_sample = samples
        .len()
        .min((start_time * sample_rate) as usize);
    let final_sample = samples.len().min((end_time * sample_rate) as usize);
    let mut chroma = [0.0f64; 12];
    let mut spectrum = vec![Complex { re: 0.0, im: 0.0 }; FRAME_SIZE];
    let mut window = vec![0.0f64; FRAME_SIZE];
    for (index, value) in window.iter_mut().enumerate() {
        *value = 0.5 - 0.5 * (2.0 * PI * index as f64 / (FRAME_SIZE - 1) as f64).cos();
    }
    let mut chroma_weight = 0.0f64;
    let mut low_energy = 0.0f64;
    let mut vocal_energy = 0.0f64;
    let mut high_energy = 0.0f64;
    let mut flatness_total = 0.0f64;
    let mut accepted_frames = 0usize;

    let mut start = first_sample;
    while start + FRAME_SIZE <= final_sample {
        let mut square_sum = 0.0f64;
        for index in 0..FRAME_SIZE {
            let value = samples[start + index] as f64;
            square_sum += value * value;
            spectrum[index] = Complex {
                re: value * window[index],
                im: 0.0,
            };
        }
        let rms = (square_sum / FRAME_SIZE as f64).sqrt();
        if rms >= 0.0025 {
            fft(&mut spectrum);

            let mut frame_chroma = 0.0f64;
            let mut log_sum = 0.0f64;
            let mut arithmetic_sum = 0.0f64;
            let mut flatness_bins = 0usize;
            let mut frame_low = 0.0f64;
            let mut frame_vocal = 0.0f64;
            let mut frame_high = 0.0f64;
            for bin in 1..FRAME_SIZE / 2 {
                let frequency = bin as f64 * sample_rate / FRAME_SIZE as f64;
                if frequency < 45.0 || frequency > 5000.0f64.min(sample_rate * 0.48) {
                    continue;
                }
                let power = spectrum[bin].re * spectrum[bin].re
                    + spectrum[bin].im * spectrum[bin].im;
                let perceptual_power = power.ln_1p();
                if frequency < 250.0 {
                    frame_low += perceptual_power;
                } else if frequency <= 4000.0 {
                    frame_vocal += perceptual_power;
                    log_sum += power.max(1e-12).ln();
                    arithmetic_sum += power;
                    flatness_bins += 1;
                } else {
                    frame_high += perceptual_power;
                }
                if frequency > 5000.0 {
                    continue;
                }
                let midi = (69.0 + 12.0 * (frequency / 440.0).log2()).round() as i64;
                let pitch_class = ((midi % 12) + 12) % 12;
                let weight = power.ln_1p();
                chroma[pitch_class as usize] += weight * rms;
                frame_chroma += weight;
            }
            let frame_flatness = if flatness_bins > 0 && arithmetic_sum > 0.0 {
                (log_sum / flatness_bins as f64).exp() / (arithmetic_sum / flatness_bins as f64)
            } else {
                0.0
            };
            flatness_total += frame_flatness;
            low_energy += frame_low;
            vocal_energy += frame_vocal;
            high_energy += frame_high;
            let mid_time = (start + FRAME_SIZE / 2) as f64 / sample_rate;
            low_frames.push(EnergyPoint {
                time: mid_time,
                energy: frame_low,
            });
            vocal_frames.push(EnergyPoint {
                time: mid_time,
                energy: vocal_probability_from(frame_low, frame_vocal, frame_high, frame_flatness),
            });
            high_frames.push(EnergyPoint {
                time: mid_time,
                energy: frame_high,
            });
            chroma_weight += (frame_chroma * rms).max(1e-9);
            accepted_frames += 1;
        }
        start += hop_size;
    }

    let chroma_sum: f64 = chroma.iter().sum();
    if chroma_sum > 0.0 {
        for value in &mut chroma {
            *value /= chroma_sum;
        }
    }

    const MAJOR: [f64; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
    const MINOR: [f64; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
    const NAMES: [&str; 12] = [
        "C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B",
    ];
    let mut candidates: Vec<(f64, String)> = Vec::with_capacity(24);
    for root in 0..12usize {
        let mut major_score = 0.0;
        let mut minor_score = 0.0;
        for pitch in 0..12usize {
            major_score += chroma[pitch] * MAJOR[(pitch + 12 - root) % 12];
            minor_score += chroma[pitch] * MINOR[(pitch + 12 - root) % 12];
        }
        candidates.push((major_score, format!("{} major", NAMES[root])));
        candidates.push((minor_score, format!("{} minor", NAMES[root])));
    }
    candidates.sort_by(|a, b| b.0.total_cmp(&a.0));
    if chroma_weight > 0.0 && !candidates.is_empty() {
        result.key = candidates[0].1.clone();
        result.key_confidence = clamp(
            (candidates[0].0 - candidates[1].0) / candidates[0].0.max(0.01) * 4.0,
            0.0,
            1.0,
        );
    }

    result.vocal_probability = vocal_probability_from(
        low_energy,
        vocal_energy,
        high_energy,
        flatness_total / accepted_frames.max(1) as f64,
    );
}

fn build_structure(envelope: &EnvelopeResult, result: &mut AudioAnalysis) {
    let phrase_seconds = if result.beat_interval > 0.0 {
        result.beat_interval * 32.0
    } else {
        16.0
    };
    let phrase_start = if !result.downbeats.is_empty() {
        result.downbeats[0]
    } else {
        envelope.audible_start
    };
    let first_window = (envelope.audible_start / envelope.window_seconds) as usize;
    let four_seconds = (4.0 / envelope.window_seconds).max(1.0) as usize;
    let quiet_windows = (3.0 / envelope.window_seconds).round().max(1.0) as usize;
    let recovery_windows = (3.0 / envelope.window_seconds).round().max(1.0) as usize;
    let mut strong_window = first_window;
    for index in first_window..envelope.levels.len() {
        if index + four_seconds > envelope.levels.len() {
            break;
        }
        if average(&envelope.levels, index, index + four_seconds) >= envelope.reference * 0.62 {
            strong_window = index;
            break;
        }
    }
    let raw_intro = (phrase_start + phrase_seconds)
        .max(strong_window as f64 * envelope.window_seconds);
    result.intro_end_time = clamp(
        nearest_downbeat(&result.downbeats, raw_intro, raw_intro),
        envelope.audible_start,
        envelope.content_end.min(48.0),
    );

    let mut raw_outro = (envelope.content_end - phrase_seconds).max(result.intro_end_time);
    let search_start = ((result.intro_end_time.max(envelope.content_end * 0.6))
        / envelope.window_seconds) as usize;
    for index in search_start..envelope.levels.len() {
        if index + four_seconds >= envelope.levels.len() {
            break;
        }
        let section_average = average(&envelope.levels, index, index + four_seconds);
        let tail_average = average(&envelope.levels, index, envelope.levels.len());
        if section_average >= envelope.reference * 0.68
            || tail_average >= envelope.reference * 0.72
        {
            continue;
        }
        if !has_quiet_then_recovery(
            &envelope.levels,
            index,
            quiet_windows.max(recovery_windows),
            envelope.reference,
        ) {
            raw_outro = index as f64 * envelope.window_seconds;
            break;
        }
    }
    result.outro_start_time = clamp(
        nearest_downbeat(&result.downbeats, raw_outro, raw_outro),
        result.intro_end_time,
        envelope.content_end,
    );

    let mut phrase_boundaries = Vec::new();
    phrase_boundaries.push(phrase_start);
    let mut time = phrase_start + phrase_seconds;
    while time < envelope.content_end {
        phrase_boundaries.push(time);
        time += phrase_seconds;
    }
    phrase_boundaries.push(result.intro_end_time);
    phrase_boundaries.push(result.outro_start_time);
    if phrase_boundaries.is_empty()
        || *phrase_boundaries.last().unwrap() < envelope.content_end - 0.05
    {
        phrase_boundaries.push(envelope.content_end);
    }
    phrase_boundaries.sort_by(|a, b| a.total_cmp(b));
    phrase_boundaries.dedup_by(|a, b| (*a - *b).abs() < 0.05);
    result.phrase_boundaries = phrase_boundaries;

    // Hierarchical structure: novelty on the envelope → sections (coarse) and
    // segments (mid). Snapped to downbeats when a grid exists — switch-point
    // literature prefers bar-aligned boundaries over arbitrary seconds.
    let (sections, segments) = novelty_boundaries(envelope, result);
    result.section_boundaries = sections;
    result.segment_boundaries = segments;
    for &time in &result.section_boundaries {
        if time > result.intro_end_time + 1.0 && time < envelope.content_end - 4.0 {
            result.mix_out_candidates.push(MixCuePoint {
                time,
                score: 0.88,
                kind: "section_boundary".into(),
            });
        }
    }

    let eight_bar_target = if result.beat_interval > 0.0 {
        phrase_start + result.beat_interval * 32.0
    } else {
        result.intro_end_time
    };
    let latest_cue = envelope
        .audible_start
        .max(36.0f64.min(envelope.content_end * 0.28));
    let bounded_target = latest_cue.min(eight_bar_target);
    result.mix_in_time = clamp(
        downbeat_at_or_before(&result.downbeats, bounded_target, bounded_target),
        envelope.audible_start,
        latest_cue,
    );
    let cue_window = (result.mix_in_time / envelope.window_seconds) as usize;
    let cue_energy = average(
        &envelope.levels,
        cue_window,
        cue_window + four_seconds,
    );
    result.mix_in_confidence = clamp(
        result.beat_confidence * 0.65
            + clamp(cue_energy / envelope.reference.max(1e-6), 0.0, 1.0) * 0.35,
        0.0,
        1.0,
    );

    // Where the track starts, and where its arrangement arrives.
    //
    // `pickup` is the entry: the first sound. `intro_drop` and `main_drop` are
    // handoff candidates — the point the outgoing track should be gone by, not
    // the point playback starts. The planner accepts a drop only when the
    // overlap can cover the distance from the entry, so a drop can never skip
    // the listener a minute into the next record.
    //
    // `main_drop` is emitted only from a real beat grid. The old fallback, when
    // `beat_interval` was 0, used `intro_end_time` (the first loud window,
    // capped at 48 s). That is a mix-out question used as a mix-in question.
    result.mix_in_candidates.push(MixCuePoint {
        time: result.audible_start_time,
        score: 0.8,
        kind: "pickup".into(),
    });
    if result.mix_in_time > result.audible_start_time + 0.1 {
        result.mix_in_candidates.push(MixCuePoint {
            time: result.mix_in_time,
            score: 0.9,
            kind: "intro_drop".into(),
        });
    }
    let has_grid = result.beat_interval > 0.0
        && (40.0..=220.0).contains(&result.bpm)
        && !result.downbeats.is_empty();
    if has_grid {
        let drop_cue = phrase_start + result.beat_interval * 32.0;
        if drop_cue > result.mix_in_time + 0.5 && drop_cue < envelope.content_end * 0.4 {
            let aligned_drop = downbeat_at_or_before(&result.downbeats, drop_cue, drop_cue);
            result.mix_in_candidates.push(MixCuePoint {
                time: aligned_drop,
                score: 0.95,
                kind: "main_drop".into(),
            });
        }
    }

    if result.mix_out_time > 0.0 && result.mix_out_time < envelope.content_end - 1.0 {
        result.mix_out_candidates.push(MixCuePoint {
            time: result.mix_out_time,
            score: 0.95,
            kind: "energy_cliff".into(),
        });
    }
    result.mix_out_candidates.push(MixCuePoint {
        time: result.outro_start_time,
        score: 0.9,
        kind: "outro_start".into(),
    });
    result.mix_out_candidates.push(MixCuePoint {
        time: envelope.content_end,
        score: 0.75,
        kind: "content_end".into(),
    });
}

/// Energy novelty peaks → section / segment starts on the downbeat grid.
fn novelty_boundaries(envelope: &EnvelopeResult, result: &AudioAnalysis) -> (Vec<f64>, Vec<f64>) {
    let levels = &envelope.levels;
    if levels.len() < 8 {
        return (Vec::new(), Vec::new());
    }
    let mut novelty = vec![0.0f64; levels.len()];
    for index in 1..levels.len() {
        novelty[index] = (levels[index] - levels[index - 1]).abs();
    }
    // Smooth a little so single-window spikes do not invent sections.
    let mut smooth = novelty.clone();
    for index in 1..novelty.len().saturating_sub(1) {
        smooth[index] = (novelty[index - 1] + novelty[index] + novelty[index + 1]) / 3.0;
    }
    let peak_threshold = percentile(&smooth, 0.85).max(envelope.reference * 0.08);
    let min_section_gap = if result.beat_interval > 0.0 {
        (result.beat_interval * 32.0).max(8.0)
    } else {
        12.0
    };
    let min_segment_gap = (min_section_gap * 0.5).max(4.0);

    let mut raw_peaks = Vec::new();
    for index in 2..smooth.len().saturating_sub(2) {
        if smooth[index] < peak_threshold {
            continue;
        }
        if smooth[index] >= smooth[index - 1] && smooth[index] >= smooth[index + 1] {
            let time = index as f64 * envelope.window_seconds;
            if time > envelope.audible_start + 2.0 && time < envelope.content_end - 2.0 {
                raw_peaks.push((time, smooth[index]));
            }
        }
    }
    raw_peaks.sort_by(|a, b| b.1.total_cmp(&a.1));

    let snap = |time: f64| -> f64 {
        if result.downbeats.is_empty() {
            return time;
        }
        result
            .downbeats
            .iter()
            .copied()
            .min_by(|a, b| (a - time).abs().total_cmp(&(b - time).abs()))
            .unwrap_or(time)
    };

    let mut sections = Vec::new();
    for &(time, _) in &raw_peaks {
        let snapped = snap(time);
        if sections
            .iter()
            .all(|existing: &f64| (existing - snapped).abs() >= min_section_gap)
        {
            sections.push(snapped);
        }
        if sections.len() >= 12 {
            break;
        }
    }
    sections.sort_by(|a, b| a.total_cmp(b));

    let mut segments = Vec::new();
    for &(time, _) in &raw_peaks {
        let snapped = snap(time);
        if sections.iter().any(|s| (s - snapped).abs() < 0.5) {
            continue;
        }
        if segments
            .iter()
            .all(|existing: &f64| (existing - snapped).abs() >= min_segment_gap)
        {
            segments.push(snapped);
        }
        if segments.len() >= 24 {
            break;
        }
    }
    segments.sort_by(|a, b| a.total_cmp(b));
    (sections, segments)
}

/// Orchestrates the envelope, tempo, level, spectral, and structure stages.
pub(crate) fn analyze_audio(
    samples: &[f32],
    sample_rate: f64,
    supplied_duration: f64,
) -> AudioAnalysis {
    let mut result = AudioAnalysis::default();
    result.duration = if supplied_duration > 0.0 {
        supplied_duration
    } else {
        samples.len() as f64 / sample_rate.max(1.0)
    };
    if samples.is_empty() || sample_rate < 1000.0 || result.duration <= 0.0 {
        return result;
    }
    let envelope = analyze_envelope(samples, sample_rate, result.duration);
    result.audible_start_time = envelope.audible_start;
    result.pickup_confidence = envelope.pickup_confidence;
    result.content_end_time = envelope.content_end;
    result.mix_out_time = find_mix_out_time(samples, sample_rate, result.duration, &envelope);

    if let Some(TempoResult {
        bpm,
        beat_interval,
        first_beat,
        confidence,
        beats,
        downbeats,
    }) = tempo::analyze_tempo(samples, sample_rate, result.duration, envelope.audible_start)
    {
        result.bpm = bpm;
        result.beat_interval = beat_interval;
        result.first_beat = first_beat;
        result.beat_confidence = confidence;
        result.beats = beats;
        result.downbeats = downbeats;
    }

    let mut square_sum = 0.0f64;
    let mut peak = 0.0f64;
    let content_start = samples
        .len()
        .min((envelope.audible_start * sample_rate) as usize);
    let content_end = samples
        .len()
        .min((envelope.content_end * sample_rate) as usize);
    for sample in &samples[content_start..content_end] {
        square_sum += (*sample as f64) * (*sample as f64);
        peak = peak.max((*sample as f64).abs());
    }
    let rms = (square_sum / (content_end - content_start).max(1) as f64).sqrt();
    result.loudness_lufs = to_db(rms).max(-70.0) - 0.691;
    result.peak_dbfs = to_db(peak);
    result.dynamic_range_db = clamp(
        to_db(percentile(&envelope.levels, 0.95)) - to_db(percentile(&envelope.levels, 0.2)),
        0.0,
        70.0,
    );

    // Downsample to at most 240 points and scale against the track reference.
    let curve_stride = ((envelope.levels.len() + 239) / 240).max(1);
    let mut index = 0usize;
    while index < envelope.levels.len() {
        let time = index as f64 * envelope.window_seconds;
        let norm = clamp(
            envelope.levels[index] / envelope.reference.max(1e-6),
            0.0,
            1.5,
        );
        result.energy_curve.push(EnergyPoint { time, energy: norm });
        index += curve_stride;
    }

    let mut low_frames = Vec::new();
    let mut vocal_frames = Vec::new();
    let mut high_frames = Vec::new();
    analyze_key_and_timbre(
        samples,
        sample_rate,
        envelope.audible_start,
        envelope.content_end,
        &mut result,
        &mut low_frames,
        &mut vocal_frames,
        &mut high_frames,
    );

    let low_values: Vec<f64> = low_frames.iter().map(|f| f.energy).collect();
    let low_reference = percentile(&low_values, 0.85);
    let high_values: Vec<f64> = high_frames.iter().map(|f| f.energy).collect();
    let high_reference = percentile(&high_values, 0.85);
    let mut low_cursor = 0usize;
    let mut high_cursor = 0usize;
    for point in &result.energy_curve {
        while low_cursor + 1 < low_frames.len()
            && (low_frames[low_cursor + 1].time - point.time).abs()
                < (low_frames[low_cursor].time - point.time).abs()
        {
            low_cursor += 1;
        }
        while high_cursor + 1 < high_frames.len()
            && (high_frames[high_cursor + 1].time - point.time).abs()
                < (high_frames[high_cursor].time - point.time).abs()
        {
            high_cursor += 1;
        }
        let bass = if low_frames.is_empty() || point.energy <= 0.1 || low_reference <= 1e-9 {
            0.0
        } else {
            clamp(low_frames[low_cursor].energy / low_reference, 0.0, 1.5)
        };
        result.low_energy_curve.push(EnergyPoint {
            time: point.time,
            energy: bass,
        });
        result.bass_activity_mask.push(bass.min(1.0));
        let drums = if high_frames.is_empty() || point.energy <= 0.1 || high_reference <= 1e-9 {
            0.0
        } else {
            clamp(high_frames[high_cursor].energy / high_reference, 0.0, 1.0)
        };
        result.drum_activity_mask.push(drums);
    }

    let mut frame_cursor = 0usize;
    for point in &result.energy_curve {
        while frame_cursor + 1 < vocal_frames.len()
            && (vocal_frames[frame_cursor + 1].time - point.time).abs()
                < (vocal_frames[frame_cursor].time - point.time).abs()
        {
            frame_cursor += 1;
        }
        let probability = if vocal_frames.is_empty() {
            result.vocal_probability
        } else {
            vocal_frames[frame_cursor].energy
        };
        result.vocal_activity_mask.push(clamp(
            probability * if point.energy > 0.25 { 1.0 } else { 0.3 },
            0.0,
            1.0,
        ));
    }

    // Pace ≈ local energy × absolute energy change (novelty). Used by the
    // sequencer and long-blend policy as an Apple Music Understanding stand-in.
    for index in 0..result.energy_curve.len() {
        let energy = result.energy_curve[index].energy;
        let prev = if index == 0 {
            energy
        } else {
            result.energy_curve[index - 1].energy
        };
        let novelty = (energy - prev).abs();
        let pace = clamp(energy * 0.65 + novelty * 1.4, 0.0, 1.0);
        result.pace_curve.push(EnergyPoint {
            time: result.energy_curve[index].time,
            energy: pace,
        });
    }

    build_structure(&envelope, &mut result);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_finds_audible_start_and_content_end() {
        let rate = 11_025.0;
        let silence_before = 2.0;
        let tone_seconds = 4.0;
        let silence_after = 1.5;
        let total = silence_before + tone_seconds + silence_after;
        let samples_len = (total * rate) as usize;
        let mut samples = vec![0.0f32; samples_len];
        let tone_start = (silence_before * rate) as usize;
        let tone_end = ((silence_before + tone_seconds) * rate) as usize;
        for index in tone_start..tone_end {
            let t = index as f64 / rate;
            samples[index] = (2.0 * PI * 440.0 * t).sin() as f32 * 0.5;
        }

        let result = analyze_audio(&samples, rate, total);

        // The pickup lands inside the leading silence→content transition.
        assert!(
            (0.5..=2.0).contains(&result.audible_start_time),
            "audible_start {} outside 0.5..2.0",
            result.audible_start_time
        );
        assert!(
            result.content_end_time > silence_before + tone_seconds - 0.75,
            "content_end {} too early",
            result.content_end_time
        );
        assert_eq!(result.pace_curve.len(), result.energy_curve.len());
        assert_eq!(result.bass_activity_mask.len(), result.energy_curve.len());
        assert_eq!(result.drum_activity_mask.len(), result.energy_curve.len());
        // Content ends where the trailing silence begins, not at file end.
        let expected_end = silence_before + tone_seconds;
        assert!(
            (expected_end - 0.5..=expected_end + 0.5).contains(&result.content_end_time),
            "content_end {} expected ~{}",
            result.content_end_time,
            expected_end
        );
        assert!(!result.energy_curve.is_empty());
        assert!(result.energy_curve.iter().all(|p| p.energy >= 0.0 && p.energy <= 1.5));
    }

    #[test]
    fn novelty_finds_section_candidates_on_an_energy_step() {
        let rate = 11_025.0;
        let total = 48.0;
        let samples_len = (total * rate) as usize;
        let mut samples = vec![0.0f32; samples_len];
        // Soft bed for the whole file so audible_start/content_end stay at the
        // edges; interior amplitude jumps produce novelty peaks that survive
        // the +2s / −2s margin around those edges.
        for index in 0..samples_len {
            let t = index as f64 / rate;
            let amp = if (12.0..28.0).contains(&t) {
                0.7
            } else if (28.0..40.0).contains(&t) {
                0.25
            } else {
                0.08
            };
            samples[index] = (2.0 * PI * 220.0 * t).sin() as f32 * amp;
        }
        let result = analyze_audio(&samples, rate, total);
        assert!(
            !result.section_boundaries.is_empty() || !result.segment_boundaries.is_empty(),
            "expected novelty boundaries on a stepped envelope; sections={:?} segments={:?} mix_out={:?}",
            result.section_boundaries,
            result.segment_boundaries,
            result.mix_out_candidates.iter().map(|c| &c.kind).collect::<Vec<_>>(),
        );
        assert!(
            result.mix_out_candidates.iter().any(|c| {
                c.kind == "section_boundary"
                    || c.kind == "energy_cliff"
                    || c.kind == "outro_start"
            }),
            "mix-out candidates should include structure or energy cues"
        );
    }
}
